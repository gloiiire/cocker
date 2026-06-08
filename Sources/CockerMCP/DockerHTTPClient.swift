import Foundation
import CockerCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Minimal HTTP/1.1 client over a Unix domain socket.
// Used to talk to cockerd's Docker-compatible API at ~/.cocker/docker.sock.

public struct DockerHTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data

    public var isSuccess: Bool { status >= 200 && status < 300 }
    public var bodyString: String { String(data: body, encoding: .utf8) ?? "" }
}

public enum DockerHTTPError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case writeFailed(String)
    case readFailed(String)
    case malformedResponse(String)
    case httpError(status: Int, message: String)

    public var description: String {
        switch self {
        case .connectionFailed(let s): return "Connection failed: \(s) — is cockerd running?"
        case .writeFailed(let s):      return "Write failed: \(s)"
        case .readFailed(let s):       return "Read failed: \(s)"
        case .malformedResponse(let s): return "Malformed response: \(s)"
        case .httpError(let status, let msg): return "HTTP \(status): \(msg)"
        }
    }
}

public actor DockerHTTPClient {
    private let socketPath: String

    public init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? DockerHTTPClient.defaultSocketPath
    }

    public static var defaultSocketPath: String {
        // DOCKER_HOST takes precedence, then default ~/.cocker/docker.sock.
        if let host = ProcessInfo.processInfo.environment["DOCKER_HOST"],
           host.hasPrefix("unix://") {
            return String(host.dropFirst(7))
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return "\(home)/.cocker/docker.sock"
    }

    public func get(_ path: String) async throws -> DockerHTTPResponse {
        try await request(method: "GET", path: path, body: nil)
    }

    public func post(_ path: String, json: Data? = nil) async throws -> DockerHTTPResponse {
        try await request(method: "POST", path: path, body: json)
    }

    public func delete(_ path: String) async throws -> DockerHTTPResponse {
        try await request(method: "DELETE", path: path, body: nil)
    }

    // MARK: - Core

    private func request(method: String, path: String, body: Data?) async throws -> DockerHTTPResponse {
        let fd = try connectSocket()
        defer { close(fd) }

        var req = "\(method) \(path) HTTP/1.1\r\n"
        req += "Host: cocker\r\n"
        req += "User-Agent: cocker-mcp/0.5.1\r\n"
        req += "Accept: application/json\r\n"
        req += "Connection: close\r\n"
        if let body = body {
            req += "Content-Type: application/json\r\n"
            req += "Content-Length: \(body.count)\r\n"
        } else {
            req += "Content-Length: 0\r\n"
        }
        req += "\r\n"

        var requestData = req.data(using: .utf8) ?? Data()
        if let body = body { requestData.append(body) }
        try writeAll(fd: fd, data: requestData)

        return try readResponse(fd: fd)
    }

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DockerHTTPError.connectionFailed(String(cString: strerror(errno)))
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { dest in
                dest.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strncpy(dest, ptr, 103)
                }
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let msg = String(cString: strerror(errno))
            close(fd)
            throw DockerHTTPError.connectionFailed("\(socketPath): \(msg)")
        }
        return fd
    }

    private func writeAll(fd: Int32, data: Data) throws {
        var remaining = data
        while !remaining.isEmpty {
            let n = remaining.withUnsafeBytes { buf in
                Darwin.write(fd, buf.baseAddress!, buf.count)
            }
            if n <= 0 {
                throw DockerHTTPError.writeFailed(String(cString: strerror(errno)))
            }
            remaining = remaining.dropFirst(n)
        }
    }

    private func readResponse(fd: Int32) throws -> DockerHTTPResponse {
        // Slurp until EOF (we sent Connection: close, so cockerd will close).
        var all = Data()
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = Darwin.read(fd, &buf, buf.count)
            if n == 0 { break }
            if n < 0 {
                throw DockerHTTPError.readFailed(String(cString: strerror(errno)))
            }
            all.append(contentsOf: buf.prefix(n))
        }
        return try parseResponse(all)
    }

    private func parseResponse(_ data: Data) throws -> DockerHTTPResponse {
        guard let headerEnd = data.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            throw DockerHTTPError.malformedResponse("no header/body boundary")
        }
        let headerData = data.prefix(upTo: headerEnd.lowerBound)
        var body = data.suffix(from: headerEnd.upperBound)

        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw DockerHTTPError.malformedResponse("non-UTF8 headers")
        }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw DockerHTTPError.malformedResponse("empty headers")
        }
        let statusParts = statusLine.components(separatedBy: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw DockerHTTPError.malformedResponse("bad status line: \(statusLine)")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        // Decode chunked if needed.
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            body = Self.decodeChunked(body)
        }

        return DockerHTTPResponse(status: status, headers: headers, body: Data(body))
    }

    private static func decodeChunked(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            // Find chunk size line (hex, ends at CRLF).
            guard let crlf = data.range(of: Data([0x0D, 0x0A]), in: i..<data.endIndex) else { break }
            let sizeStr = String(data: data[i..<crlf.lowerBound], encoding: .utf8) ?? ""
            let sizeHex = sizeStr.components(separatedBy: ";").first ?? sizeStr
            guard let size = Int(sizeHex.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            i = crlf.upperBound
            if size == 0 { break }
            let end = data.index(i, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
            out.append(data[i..<end])
            i = end
            // Skip trailing CRLF.
            if i < data.endIndex, data[i] == 0x0D { i = data.index(i, offsetBy: 2, limitedBy: data.endIndex) ?? data.endIndex }
        }
        return out
    }
}

// MARK: - URL helpers

public enum URLBuilder {
    public static func query(_ params: [String: String]) -> String {
        guard !params.isEmpty else { return "" }
        let pairs = params.map { k, v in
            "\(escape(k))=\(escape(v))"
        }.sorted().joined(separator: "&")
        return "?" + pairs
    }

    public static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }
}
