import Foundation

// Unix domain socket transport — used by the CLI to talk to cockerd
// Protocol: 4-byte big-endian length prefix + JSON payload

public actor IPCClient {
    private let socketPath: String
    private var fd: Int32 = -1

    public init(socketPath: String = IPCClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    public static var defaultSocketPath: String {
        // Respecte COCKER_HOST env var en premier (ou DOCKER_HOST pour compatibilité)
        if let host = ProcessInfo.processInfo.environment["COCKER_HOST"] ?? ProcessInfo.processInfo.environment["DOCKER_HOST"] {
            if host.hasPrefix("unix://") { return String(host.dropFirst(7)) }
        }
        // Ensuite le contexte actuel
        return ContextStore.load().currentSocketPath
    }

    public func connect() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw CockerError.connectionFailed(String(cString: strerror(errno))) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { dest in
                dest.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strncpy(dest, ptr, 103)
                }
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(sock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(sock)
            throw CockerError.daemonNotRunning
        }
        self.fd = sock
    }

    public func disconnect() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    public func send(_ request: IPCRequest) async throws -> IPCResponse {
        if fd < 0 { try connect() }
        let data = try JSONEncoder().encode(request)
        try writeFrame(data)
        let responseData = try readFrame()
        guard let response = try? JSONDecoder().decode(IPCResponse.self, from: responseData) else {
            throw CockerError.responseDecodingFailed("Could not decode response")
        }
        if !response.success, let err = response.error {
            throw CockerError.requestFailed(err)
        }
        return response
    }

    // For streaming responses (logs, build output, events)
    public func sendStreaming(_ request: IPCRequest, handler: @escaping @Sendable (StreamEvent) -> Void) async throws {
        if fd < 0 { try connect() }
        let data = try JSONEncoder().encode(request)
        try writeFrame(data)

        while true {
            let frameData: Data
            do {
                frameData = try readFrame()
            } catch CockerError.daemonNotRunning {
                // Clean EOF from the daemon after the last frame was sent.
                // `compose logs -f` hits this when every followed container
                // exits — the task group drains, the streaming operation
                // closes its side, and our next read returns 0. Treat as
                // normal end-of-stream, not as a crash.
                return
            }
            // Zero-length frame = explicit clean close sentinel. Some
            // streaming paths emit one before tearing down (notably
            // composeLogs when all child log streams finish at once).
            // Without this short-circuit we'd hand an empty Data() to
            // JSONDecoder and surface the very confusing
            // "DecodingError.dataCorrupted: Unexpected character around
            // line 1, column 1" the user actually saw.
            if frameData.isEmpty { return }
            let response = try JSONDecoder().decode(IPCResponse.self, from: frameData)
            if !response.success, let err = response.error {
                throw CockerError.requestFailed(err)
            }
            if response.isStreaming {
                let event = try response.decode(StreamEvent.self)
                handler(event)
                if response.isLast { break }
            } else {
                break
            }
        }
    }

    private func writeFrame(_ data: Data) throws {
        var length = UInt32(data.count).bigEndian
        let headerData = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(headerData)
        try writeAll(data)
    }

    private func readFrame() throws -> Data {
        let header = try readExactly(4)
        // **I2 fix** : `load(as:)` requires its buffer to satisfy the
        // target type's alignment. `Data`'s underlying storage doesn't
        // guarantee that — `loadUnaligned` is documented to do the right
        // thing on every supported architecture and is what Apple's own
        // sample code switched to in Swift 5.7+.
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length < 100 * 1024 * 1024 else {  // 100 MB sanity limit
            throw CockerError.responseDecodingFailed("Frame too large: \(length)")
        }
        return try readExactly(Int(length))
    }

    private func writeAll(_ data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }
            if n <= 0 {
                throw CockerError.connectionFailed("Write failed: \(String(cString: strerror(errno)))")
            }
            remaining = remaining.dropFirst(n)
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data(capacity: count)
        while result.count < count {
            var buf = [UInt8](repeating: 0, count: count - result.count)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 {
                throw n == 0
                    ? CockerError.daemonNotRunning
                    : CockerError.connectionFailed("Read failed: \(String(cString: strerror(errno)))")
            }
            result.append(contentsOf: buf.prefix(n))
        }
        return result
    }
}

// MARK: - Server-side frame reader/writer (used by daemon)

public enum IPCFramer {
    public static func write(_ data: Data, to fd: Int32) throws {
        var length = UInt32(data.count).bigEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        try writeAll(header, to: fd)
        try writeAll(data, to: fd)
    }

    public static func read(from fd: Int32) throws -> Data {
        let header = try readExactly(4, from: fd)
        // Mirror Transport.IPCClient.readFrame's I2 fix : `loadUnaligned`
        // is safer than `load` on Data-backed buffers.
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard length < 100 * 1024 * 1024 else {
            throw CockerError.responseDecodingFailed("Frame too large")
        }
        return try readExactly(Int(length), from: fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }
            guard n > 0 else { throw CockerError.connectionFailed("Write error") }
            remaining = remaining.dropFirst(n)
        }
    }

    private static func readExactly(_ count: Int, from fd: Int32) throws -> Data {
        var result = Data(capacity: count)
        while result.count < count {
            var buf = [UInt8](repeating: 0, count: count - result.count)
            let n = Darwin.read(fd, &buf, buf.count)
            guard n > 0 else { throw CockerError.connectionFailed("Connection closed") }
            result.append(contentsOf: buf.prefix(n))
        }
        return result
    }
}
