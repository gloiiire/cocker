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
        guard let url = URL(string: "https://\(ref.registry)/v2/\(ref.repository)/manifests/\(selector.dropFirst())") else {
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

    // MARK: - Layer download

    public func downloadLayer(
        ref: ImageReference,
        descriptor: OCIDescriptor,
        destination: URL,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        let token = try await authenticate(registry: ref.registry, repository: ref.repository)

        guard let url = URL(string: "https://\(ref.registry)/v2/\(ref.repository)/blobs/\(descriptor.digest)") else {
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

    private func authenticate(registry: String, repository: String) async throws -> String? {
        if let cached = tokens[registry] { return cached }

        // Load from CredentialStore if not already set
        if credentials[registry] == nil {
            let store = CredentialStore.load()
            if let cred = store.get(for: registry) {
                credentials[registry] = (cred.username, cred.password)
            }
        }

        // Try anonymous pull first
        guard let url = URL(string: "https://\(registry)/v2/") else { return nil }
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
              let token = try await requestToken(wwwAuth: wwwAuth, registry: registry, repository: repository)
        else { return nil }

        tokens[registry] = token
        return token
    }

    private func requestToken(wwwAuth: String, registry: String, repository: String) async throws -> String? {
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
        queryItems.append(.init(name: "scope", value: "repository:\(repository):pull"))
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
        guard let url = URL(string: "https://\(ref.registry)/v2/\(ref.repository)/blobs/\(digest)") else {
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
