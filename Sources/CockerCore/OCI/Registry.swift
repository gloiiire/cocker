import Foundation
import Crypto

// Docker Registry API v2 client

public actor RegistryClient {
    private let session: URLSession
    private var tokens: [String: String] = [:]  // registry -> Bearer token
    private var credentials: [String: (String, String)] = [:]  // registry -> (user, pass)

    public init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }

    public func addCredential(registry: String, username: String, password: String) {
        credentials[registry] = (username, password)
    }

    /// Build a base v2 URL for `ref`. Local / private-network registries get
    /// plain http (they don't terminate TLS) ; everything else gets https.
    /// Centralises the rule so push / pull / blob fetches all agree.
    private func v2URL(ref: ImageReference, path: String) -> URL? {
        let host = ref.registry.split(separator: ":").first.map(String.init) ?? ref.registry
        let scheme: String = (host == "localhost" || host == "127.0.0.1"
            || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("172."))
            ? "http" : "https"
        return URL(string: "\(scheme)://\(ref.registry)/v2/\(ref.repository)/\(path)")
    }

    // MARK: - Manifest resolution

    public func resolveManifest(for ref: ImageReference) async throws -> (OCIManifest, String) {
        let token = try await authenticate(registry: ref.registry, repository: ref.repository)

        // First try the index (multi-arch)
        let indexResult = try? await fetchManifest(ref: ref, token: token, accept: [
            MediaType.ociIndex,
            MediaType.manifestListV2,
        ])

        if let (indexData, _) = indexResult,
           let index = try? JSONDecoder().decode(OCIIndex.self, from: indexData),
           let selected = selectPlatform(from: index.manifests) {
            // Resolve the platform-specific manifest
            let platformRef = ImageReference(
                registry: ref.registry,
                repository: ref.repository,
                tag: ref.tag,
                digest: selected.digest
            )
            let (manifestData, digest) = try await fetchManifest(ref: platformRef, token: token, accept: [
                MediaType.ociManifest,
                MediaType.manifestV2,
            ])
            let manifest = try JSONDecoder().decode(OCIManifest.self, from: manifestData)
            return (manifest, digest)
        }

        // Direct manifest
        let (manifestData, digest) = try await fetchManifest(ref: ref, token: token, accept: [
            MediaType.ociManifest,
            MediaType.manifestV2,
            MediaType.manifestListV2,
        ])
        let manifest = try JSONDecoder().decode(OCIManifest.self, from: manifestData)
        return (manifest, digest)
    }

    private func fetchManifest(ref: ImageReference, token: String?, accept: [String]) async throws -> (Data, String) {
        let selector = ref.digest.map { "@\($0)" } ?? ":\(ref.tag)"
        guard let url = v2URL(ref: ref, path: "manifests/\(selector.dropFirst())") else {
            throw CockerError.invalidImageReference(ref.fullName)
        }

        var request = URLRequest(url: url)
        request.setValue(accept.joined(separator: ", "), forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CockerError.imagePullFailed(ref.fullName, "Invalid response")
        }
        guard http.statusCode == 200 else {
            throw CockerError.manifestNotFound(ref.fullName)
        }

        let digest = http.value(forHTTPHeaderField: "Docker-Content-Digest") ?? sha256(data)
        return (data, digest)
    }

    // MARK: - Config

    public func fetchConfig(ref: ImageReference, descriptor: OCIDescriptor) async throws -> OCIImageConfig {
        let token = try await authenticate(registry: ref.registry, repository: ref.repository)
        let data = try await fetchBlob(ref: ref, digest: descriptor.digest, token: token)
        return try JSONDecoder().decode(OCIImageConfig.self, from: data)
    }

    // MARK: - Push

    /// OCI Distribution API v2 push : upload every blob (config + each layer),
    /// then PUT the manifest under the target tag. Returns the manifest
    /// digest the registry stored.
    ///
    /// Caller is responsible for providing each blob's raw bytes via
    /// `blobLoader` — typically the local ImageStore reading from
    /// `blobs/sha256/<digest>`. The push is sequential ; large registries
    /// support chunked uploads but the monolithic PUT path is universal.
    public func push(
        ref: ImageReference,
        manifestData: Data,
        manifestMediaType: String,
        blobs: [OCIDescriptor],
        blobLoader: (String) throws -> Data,
        progress: ((String) -> Void)? = nil
    ) async throws {
        let token = try await authenticate(registry: ref.registry,
                                           repository: ref.repository,
                                           scope: "push")

        // 1. Each blob (config + layers). Skip any the registry already has.
        for blob in blobs {
            progress?("status|\(String(blob.digest.prefix(19)))|Checking|0|\(blob.size)")
            if try await blobExists(ref: ref, digest: blob.digest, token: token) {
                progress?("status|\(String(blob.digest.prefix(19)))|Already exists|\(blob.size)|\(blob.size)")
                continue
            }
            let data = try blobLoader(blob.digest)
            progress?("status|\(String(blob.digest.prefix(19)))|Pushing|0|\(blob.size)")
            try await uploadBlob(ref: ref, digest: blob.digest, data: data, token: token)
            progress?("status|\(String(blob.digest.prefix(19)))|Pushed|\(blob.size)|\(blob.size)")
        }

        // 2. Manifest — PUT to /v2/<name>/manifests/<reference>.
        progress?("status|\(ref.shortName)|Pushing manifest|0|\(manifestData.count)")
        try await uploadManifest(ref: ref, data: manifestData, mediaType: manifestMediaType, token: token)
        progress?("status|\(ref.shortName)|Pushed|\(manifestData.count)|\(manifestData.count)")
    }

    private func blobExists(ref: ImageReference, digest: String, token: String?) async throws -> Bool {
        guard let url = v2URL(ref: ref, path: "blobs/\(digest)") else {
            return false
        }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        // Some registries (local registry:2) accept plain http on localhost ;
        // upgrade transparently if the https scheme errors out.
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            // Retry over http if https fails — important for `127.0.0.1:5000`
            // style local registries.
            guard let httpURL = URL(string: "http://\(ref.registry)/v2/\(ref.repository)/blobs/\(digest)") else { return false }
            var req2 = URLRequest(url: httpURL); req2.httpMethod = "HEAD"
            if let token { req2.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await session.data(for: req2)
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }

    private func uploadBlob(ref: ImageReference, digest: String, data: Data, token: String?) async throws {
        // Step A : POST to /v2/<name>/blobs/uploads/ → 202 Accepted + Location.
        let startURL = try pushURL(ref: ref, path: "blobs/uploads/")
        var start = URLRequest(url: startURL)
        start.httpMethod = "POST"
        if let token { start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, startResp) = try await session.data(for: start)
        guard let startHTTP = startResp as? HTTPURLResponse,
              (startHTTP.statusCode == 202 || startHTTP.statusCode == 201),
              let location = startHTTP.value(forHTTPHeaderField: "Location") else {
            throw CockerError.layerDownloadFailed(digest, "POST uploads/ failed: \((startResp as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        // Step B : PUT to <Location>?digest=<sha256:...>.
        // The Location may be absolute OR relative.
        let putURL: URL
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            putURL = URL(string: "\(location)\(location.contains("?") ? "&" : "?")digest=\(digest)")!
        } else {
            putURL = URL(string: "\(startURL.scheme!)://\(startURL.host!)\(startURL.port.map { ":\($0)" } ?? "")\(location)\(location.contains("?") ? "&" : "?")digest=\(digest)")!
        }
        var put = URLRequest(url: putURL)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        put.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        if let token { put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, putResp) = try await session.upload(for: put, from: data)
        guard let putHTTP = putResp as? HTTPURLResponse,
              putHTTP.statusCode == 201 || putHTTP.statusCode == 204 else {
            throw CockerError.layerDownloadFailed(digest, "PUT blob failed: \((putResp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }

    private func uploadManifest(ref: ImageReference, data: Data, mediaType: String, token: String?) async throws {
        let url = try pushURL(ref: ref, path: "manifests/\(ref.tag)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await session.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 201 || http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw CockerError.layerDownloadFailed(ref.tag, "PUT manifest failed: HTTP \(code)")
        }
    }

    /// Build the v2 base URL, trying https first and falling back to http for
    /// localhost-style registries that don't terminate TLS.
    private func pushURL(ref: ImageReference, path: String) throws -> URL {
        // Local + bare-IP registries are typically plain-text http.
        let scheme: String = {
            let host = ref.registry.split(separator: ":").first.map(String.init) ?? ref.registry
            if host == "localhost" || host == "127.0.0.1" || host.hasPrefix("10.")
                || host.hasPrefix("192.168.") || host.hasPrefix("172.") {
                return "http"
            }
            return "https"
        }()
        guard let url = URL(string: "\(scheme)://\(ref.registry)/v2/\(ref.repository)/\(path)") else {
            throw CockerError.layerDownloadFailed(ref.repository, "bad push URL for \(ref.fullName)")
        }
        return url
    }

    // MARK: - Layer download

    public func downloadLayer(
        ref: ImageReference,
        descriptor: OCIDescriptor,
        destination: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        let token = try await authenticate(registry: ref.registry, repository: ref.repository)

        guard let url = v2URL(ref: ref, path: "blobs/\(descriptor.digest)") else {
            throw CockerError.layerDownloadFailed(descriptor.digest, "Invalid URL")
        }

        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let tmpURL = destination.appendingPathExtension("tmp")
        let (tmpFile, response) = try await session.download(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CockerError.layerDownloadFailed(descriptor.digest, "HTTP error")
        }

        try FileManager.default.moveItem(at: tmpFile, to: tmpURL)

        // Verify digest
        let data = try Data(contentsOf: tmpURL)
        let computed = sha256(data)
        let expected = descriptor.digest.hasPrefix("sha256:") ? String(descriptor.digest.dropFirst(7)) : descriptor.digest
        guard computed == "sha256:\(expected)" || computed == expected else {
            try? FileManager.default.removeItem(at: tmpURL)
            throw CockerError.layerDownloadFailed(descriptor.digest, "Digest mismatch")
        }

        try FileManager.default.moveItem(at: tmpURL, to: destination)
    }

    // MARK: - Auth

    private func authenticate(registry: String, repository: String, scope: String = "pull") async throws -> String? {
        // Cache key includes the scope so push and pull don't share tokens.
        let cacheKey = "\(registry)|\(scope)"
        if let cached = tokens[cacheKey] { return cached }
        if let cached = tokens[registry], scope == "pull" { return cached }

        // Load from CredentialStore if not already set
        if credentials[registry] == nil {
            let store = CredentialStore.load()
            if let cred = store.get(for: registry) {
                credentials[registry] = (cred.username, cred.password)
            }
        }

        // Try anonymous pull first. Local / private-network registries are
        // typically plain http ; everything else gets https.
        let scheme: String = {
            let host = registry.split(separator: ":").first.map(String.init) ?? registry
            if host == "localhost" || host == "127.0.0.1" || host.hasPrefix("10.")
                || host.hasPrefix("192.168.") || host.hasPrefix("172.") {
                return "http"
            }
            return "https"
        }()
        guard let url = URL(string: "\(scheme)://\(registry)/v2/") else { return nil }
        var req = URLRequest(url: url)

        if let (user, pass) = credentials[registry] {
            let cred = Data("\(user):\(pass)".utf8).base64EncodedString()
            req.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        }

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return nil }

        if http.statusCode == 200 { return nil }

        guard http.statusCode == 401,
              let wwwAuth = http.value(forHTTPHeaderField: "WWW-Authenticate"),
              let token = try await requestToken(wwwAuth: wwwAuth, registry: registry, repository: repository, scope: scope)
        else { return nil }

        tokens[cacheKey] = token
        return token
    }

    private func requestToken(wwwAuth: String, registry: String, repository: String, scope: String = "pull") async throws -> String? {
        // Parse: Bearer realm="...",service="...",scope="..."
        var params: [String: String] = [:]
        let parts = wwwAuth.dropFirst("Bearer ".count).components(separatedBy: ",")
        for part in parts {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                params[String(kv[0])] = String(kv[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }

        guard let realm = params["realm"] else { return nil }
        var components = URLComponents(string: realm)
        var queryItems = components?.queryItems ?? []
        if let service = params["service"] { queryItems.append(.init(name: "service", value: service)) }
        // OCI distribution spec: scope values are comma-separated actions.
        // "push" implicitly grants "pull" but some registries (Docker Hub)
        // need both explicit for cross-repo blob mounting to work.
        let scopeActions = scope == "push" ? "push,pull" : scope
        queryItems.append(.init(name: "scope", value: "repository:\(repository):\(scopeActions)"))
        components?.queryItems = queryItems

        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)

        if let (user, pass) = credentials[registry] {
            let cred = Data("\(user):\(pass)".utf8).base64EncodedString()
            request.setValue("Basic \(cred)", forHTTPHeaderField: "Authorization")
        }

        let (data, _) = try await session.data(for: request)
        struct TokenResponse: Decodable { let token: String?; let access_token: String? }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return resp.token ?? resp.access_token
    }

    // MARK: - Blob fetch

    private func fetchBlob(ref: ImageReference, digest: String, token: String?) async throws -> Data {
        guard let url = v2URL(ref: ref, path: "blobs/\(digest)") else {
            throw CockerError.imagePullFailed(ref.fullName, "Invalid blob URL")
        }
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CockerError.imagePullFailed(ref.fullName, "Blob fetch failed")
        }
        return data
    }

    // MARK: - Platform selection

    private func selectPlatform(from manifests: [OCIManifestDescriptor]) -> OCIManifestDescriptor? {
        let arch: String
        #if arch(arm64)
        arch = "arm64"
        #else
        arch = "amd64"
        #endif

        return manifests.first { m in
            guard let p = m.platform else { return false }
            return p.os == "linux" && p.architecture == arch
        } ?? manifests.first { m in
            m.platform?.os == "linux"
        }
    }

    // MARK: - Utilities

    private func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
