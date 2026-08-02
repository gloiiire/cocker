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

    /// Whether `host` is a loopback or RFC1918 private-network address — i.e.
    /// a registry we may reach over plain http.
    ///
    /// This must NOT be a string-prefix test. `host.hasPrefix("172.")` spans
    /// all of 172.0.0.0/8, most of which is *public* internet (the private
    /// block is only 172.16.0.0/12). The old prefix check let cocker classify
    /// a public host as local and send it Bearer/Basic credentials over
    /// cleartext http — a TLS-stripping credential leak. We parse the dotted
    /// quad and match the actual RFC1918 / loopback ranges; any hostname or
    /// IPv6 literal is treated as remote (https) to fail safe.
    static func isLocalRegistry(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let parts = host.split(separator: ".")
        guard parts.count == 4,
              let a = UInt8(parts[0]), let b = UInt8(parts[1]),
              UInt8(parts[2]) != nil, UInt8(parts[3]) != nil else {
            return false
        }
        if a == 127 { return true }                          // 127.0.0.0/8 loopback
        if a == 10 { return true }                           // 10.0.0.0/8
        if a == 192 && b == 168 { return true }              // 192.168.0.0/16
        if a == 172 && (16...31).contains(b) { return true } // 172.16.0.0/12
        return false
    }

    /// Build a base v2 URL for `ref`. Local / private-network registries get
    /// plain http (they don't terminate TLS) ; everything else gets https.
    /// Centralises the rule so push / pull / blob fetches all agree.
    private func v2URL(ref: ImageReference, path: String) -> URL? {
        let host = ref.registry.split(separator: ":").first.map(String.init) ?? ref.registry
        let scheme: String = Self.isLocalRegistry(host) ? "http" : "https"
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

    /// Human explanation for a non-200, non-404 registry response.
    ///
    /// Every one of these used to surface as "Manifest not found", which
    /// named the wrong cause : the image existed, the request was refused.
    /// Each case names what happened and what to do about it.
    static func pullFailureExplanation(status: Int) -> String {
        switch status {
        case 401, 403:
            return "not authorized (\(status)) — the registry refused the "
                + "token; run `cocker login` if the image is private"
        case 429:
            return "rate limited by the registry (429) — wait, or "
                + "authenticate with `cocker login` for a higher quota"
        case 500...599:
            return "registry error (\(status)) — this is on the registry "
                + "side, retrying usually works"
        default:
            return "unexpected HTTP \(status) from the registry"
        }
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
        // Only a real 404 means "this image does not exist". Reporting 401
        // or 429 as "Manifest not found" sent people hunting for a typo in
        // an image name that was perfectly correct — the actual causes are
        // an expired/mis-scoped token and Docker Hub rate limiting.
        guard http.statusCode == 200 else {
            if http.statusCode == 404 {
                throw CockerError.manifestNotFound(ref.fullName)
            }
            throw CockerError.imagePullFailed(
                ref.fullName, Self.pullFailureExplanation(status: http.statusCode))
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
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            // Fall back to plain http ONLY for a local / private registry
            // (e.g. 127.0.0.1:5000 registry:2). NEVER downgrade — and never
            // resend the bearer token in cleartext — for a public host: an
            // on-path attacker who fails the https attempt would otherwise
            // strip TLS and read the push credential off the wire.
            let host = ref.registry.split(separator: ":").first.map(String.init) ?? ref.registry
            guard Self.isLocalRegistry(host) else { throw error }
            guard let httpURL = URL(string: "http://\(ref.registry)/v2/\(ref.repository)/blobs/\(digest)") else { return false }
            var req2 = URLRequest(url: httpURL); req2.httpMethod = "HEAD"
            if let token { req2.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await session.data(for: req2)
            return (response as? HTTPURLResponse)?.statusCode == 200
        }
    }

    /// Resolve the blob-upload `PUT` target from a registry's `Location`
    /// header, which may be absolute or relative to the registry.
    ///
    /// `location` is remote input, so this returns nil rather than
    /// force-unwrapping `URL(string:)` — a header carrying a space, a control
    /// character or a non-ASCII byte used to crash the whole daemon mid-push.
    static func uploadPutURL(location: String, base: URL, digest: String) -> URL? {
        guard !location.isEmpty else { return nil }
        let separator = location.contains("?") ? "&" : "?"
        let candidate: String
        if location.hasPrefix("http://") || location.hasPrefix("https://") {
            candidate = "\(location)\(separator)digest=\(digest)"
        } else {
            guard let scheme = base.scheme, let host = base.host else { return nil }
            let port = base.port.map { ":\($0)" } ?? ""
            // A relative Location is defined against the registry root and
            // always starts with '/'; tolerate a server that omits it.
            let path = location.hasPrefix("/") ? location : "/\(location)"
            candidate = "\(scheme)://\(host)\(port)\(path)\(separator)digest=\(digest)"
        }
        return URL(string: candidate)
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
        //
        // `location` is a header from a remote server, so it cannot be
        // force-unwrapped through `URL(string:)` — a value with a space, a
        // control character or a non-ASCII byte makes that return nil, and
        // this used to crash the whole daemon mid-push.
        guard let putURL = Self.uploadPutURL(location: location, base: startURL, digest: digest) else {
            throw CockerError.layerDownloadFailed(
                digest, "registry returned an unusable upload Location: \(location)")
        }
        var put = URLRequest(url: putURL)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        put.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        // Only send the bearer token to the registry that issued it. A
        // Location pointing at another host is a normal blob-storage handoff
        // and carries its own pre-signed credentials; forwarding ours there
        // would hand a push token to a third party the registry named.
        if let token, putURL.host == startURL.host {
            put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
        // Local + private-network registries are typically plain-text http.
        let scheme: String = {
            let host = ref.registry.split(separator: ":").first.map(String.init) ?? ref.registry
            return Self.isLocalRegistry(host) ? "http" : "https"
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

    /// Cache key for a bearer token.
    ///
    /// The repository is part of the key on purpose. Docker Hub issues a
    /// token scoped to ONE repository, so reusing the token obtained for
    /// `library/alpine` to fetch `library/busybox` gets a 401 — which
    /// `fetchManifest` used to report as "Manifest not found", making a
    /// perfectly existing image look absent. Symptom: the first pull of a
    /// session works and every later one fails.
    ///
    /// Exposed (not private) so a test can pin the invariant without
    /// reaching the network.
    ///
    /// Fields are length-prefixed rather than joined by a separator : a
    /// registry named `r|x` with repository `d` would otherwise collide
    /// with registry `r` and repository `x|d`, handing one context's token
    /// to another. Unlikely on Docker Hub, cheap to make impossible.
    static func tokenCacheKey(registry: String, repository: String, scope: String) -> String {
        [registry, repository, scope]
            .map { "\($0.count):\($0)" }
            .joined(separator: "|")
    }

    private func authenticate(registry: String, repository: String, scope: String = "pull") async throws -> String? {
        let cacheKey = Self.tokenCacheKey(
            registry: registry, repository: repository, scope: scope)
        if let cached = tokens[cacheKey] { return cached }

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
            return Self.isLocalRegistry(host) ? "http" : "https"
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
