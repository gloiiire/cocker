import Foundation
import CockerCore

// Minimal HTTP/1.1 parser for the Docker-compatible API server
// Docker Engine API over Unix socket uses plain HTTP/1.1

enum HTTPLimits {
    /// Largest request body we will buffer, in bytes (100 MiB) — matches the
    /// IPC framer's cap. Headers are already bounded to 64 KiB ; without this
    /// a client advertising `Content-Length: 9999999999` would make the
    /// daemon allocate gigabytes and stall. Over the TLS/TCP surface that is
    /// a cheap denial-of-service, so we refuse the request outright once the
    /// declared length exceeds the cap.
    static let maxBodyBytes = 100 * 1024 * 1024
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var contentType: String { headers["content-type"] ?? headers["Content-Type"] ?? "" }
    var contentLength: Int { Int(headers["content-length"] ?? headers["Content-Length"] ?? "0") ?? 0 }
}

enum HTTPMethod: String {
    case GET, POST, PUT, DELETE, HEAD, OPTIONS, PATCH
}

struct HTTPResponse {
    var status: Int
    var statusText: String
    var headers: [String: String]
    var body: Data

    init(status: Int = 200, statusText: String = "OK", headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.body = body
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(value)) ?? Data()
        return HTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: data
        )
    }

    static func error(_ message: String, status: Int = 500) -> HTTPResponse {
        json(DockerErrorResponse(message: message), status: status)
    }

    static func noContent() -> HTTPResponse {
        HTTPResponse(status: 204, statusText: "No Content")
    }

    static func notFound(_ id: String = "") -> HTTPResponse {
        error("No such container, image, network or volume: \(id)", status: 404)
    }

    static func conflict(_ msg: String) -> HTTPResponse {
        error(msg, status: 409)
    }

    func serialize() -> Data {
        var raw = "HTTP/1.1 \(status) \(statusText)\r\n"
        raw += "Server: cocker/\(CockerVersion.version)\r\n"
        for (k, v) in headers { raw += "\(k): \(v)\r\n" }
        raw += "Content-Length: \(body.count)\r\n"
        raw += "\r\n"
        var data = raw.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }
}

// MARK: - HTTP streaming response (for logs, events, pull progress)

struct HTTPStreamWriter {
    let fd: Int32

    func writeHeaders(status: Int = 200, contentType: String = "application/json") {
        let headers = "HTTP/1.1 \(status) OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nServer: cocker/\(CockerVersion.version)\r\n\r\n"
        if let data = headers.data(using: .utf8) {
            writeRaw(data)
        }
    }

    func writeChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        let header = String(format: "%X\r\n", data.count)
        if let h = header.data(using: .utf8) { writeRaw(h) }
        writeRaw(data)
        writeRaw(Data([0x0D, 0x0A]))  // \r\n
    }

    func writeChunk(_ string: String) {
        writeChunk(Data(string.utf8))
    }

    func finish() {
        // Final zero-length chunk
        writeRaw(Data("0\r\n\r\n".utf8))
    }

    // Docker log multiplexing format (8-byte header per frame)
    // Used when container has no TTY
    func writeLogFrame(stream: UInt8, data: Data) {
        var header = Data(count: 8)
        header[0] = stream  // 1=stdout, 2=stderr
        let size = UInt32(data.count).bigEndian
        withUnsafeBytes(of: size) { bytes in
            header[4] = bytes[0]; header[5] = bytes[1]
            header[6] = bytes[2]; header[7] = bytes[3]
        }
        writeChunk(header + data)
    }

    private func writeRaw(_ data: Data) {
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress else { return }
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(fd, ptr.advanced(by: sent), buf.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}

// MARK: - HTTP/1.1 request parser

func parseHTTPRequest(from fd: Int32) throws -> HTTPRequest? {
    var headerData = Data()
    var byte = [UInt8](repeating: 0, count: 1)

    // Read until \r\n\r\n (end of headers)
    while true {
        let n = Darwin.read(fd, &byte, 1)
        if n <= 0 { return nil }
        headerData.append(byte[0])
        if headerData.suffix(4) == Data([0x0D, 0x0A, 0x0D, 0x0A]) { break }
        if headerData.count > 65536 { return nil }  // Header too large
    }

    guard let rawHeaders = String(data: headerData, encoding: .utf8) else { return nil }
    let lines = rawHeaders.components(separatedBy: "\r\n")
    guard !lines.isEmpty else { return nil }

    // Parse request line
    let requestParts = lines[0].split(separator: " ", maxSplits: 2).map(String.init)
    guard requestParts.count >= 2 else { return nil }
    let method = requestParts[0]
    let rawPath = requestParts.count >= 2 ? requestParts[1] : "/"

    // Split path and query string
    var path = rawPath
    var query: [String: String] = [:]
    if let qIdx = rawPath.firstIndex(of: "?") {
        path = String(rawPath[..<qIdx])
        let queryString = String(rawPath[rawPath.index(after: qIdx)...])
        for pair in queryString.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                query[k] = v
            } else if kv.count == 1 {
                query[String(kv[0])] = ""
            }
        }
    }

    // Strip API version prefix (e.g. /v1.47/containers -> /containers)
    if path.hasPrefix("/v") {
        let afterV = path.dropFirst(2)
        if let slash = afterV.firstIndex(of: "/") {
            path = String(afterV[slash...])
        }
    }

    // Parse headers
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        let parts = line.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
            headers[String(parts[0]).lowercased()] = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
    }

    // Read body if present
    var body = Data()
    if let lengthStr = headers["content-length"], let length = Int(lengthStr), length > 0 {
        // Refuse oversize bodies before allocating anything for them.
        if length > HTTPLimits.maxBodyBytes { return nil }
        var remaining = length
        while remaining > 0 {
            var buf = [UInt8](repeating: 0, count: min(remaining, 65536))
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            body.append(contentsOf: buf.prefix(n))
            remaining -= n
        }
    }

    return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
}

// MARK: - Helpers

func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    try? JSONDecoder().decode(type, from: data)
}
