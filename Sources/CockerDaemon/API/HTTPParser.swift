import Foundation
import CockerCore

// Minimal HTTP/1.1 parser for the Docker-compatible API server
// Docker Engine API over Unix socket uses plain HTTP/1.1

enum HTTPLimits {
    /// Largest request body we will buffer, in bytes (100 MiB) — matches the
    /// IPC framer's cap. Without this a client advertising
    /// `Content-Length: 9999999999` would make the daemon allocate gigabytes
    /// and stall. Over the TLS/TCP surface that is a cheap denial-of-service,
    /// so we refuse the request outright once the declared length exceeds the
    /// cap.
    static let maxBodyBytes = 100 * 1024 * 1024

    /// Largest header section (everything before the blank `\r\n\r\n` line) we
    /// will accumulate, in bytes (64 KiB). A client that keeps sending header
    /// bytes without ever terminating the section would otherwise grow the
    /// receive buffer without bound. Both the Unix-socket fd parser and the
    /// TLS listener enforce this same cap.
    static let maxHeaderBytes = 64 * 1024
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

    @discardableResult
    func write(to fd: Int32) -> Bool {
        serialize().writeAll(to: fd)
    }
}

extension Data {
    @discardableResult
    func writeAll(to fd: Int32) -> Bool {
        withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return true }
            var sent = 0
            while sent < buf.count {
                let n = Darwin.write(fd, base.advanced(by: sent), buf.count - sent)
                if n > 0 {
                    sent += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

// MARK: - HTTP streaming response (for logs, events, pull progress)

struct HTTPStreamWriter {
    let fd: Int32

    /// Raw (hijacked) mode: bytes go out untouched, with no chunk framing.
    ///
    /// Docker's `/attach` and `/exec/{id}/start` are hijacked connections —
    /// the Go client stops speaking HTTP after the response line and reads
    /// the socket directly. Emitting `Transfer-Encoding: chunked` on those
    /// put chunk-size lines *inside* the stdcopy stream, so every client
    /// choked on "unrecognized input header" or silently mangled the output.
    var isRaw: Bool = false

    func writeHeaders(status: Int = 200, contentType: String = "application/json") {
        let reason = Self.reasonPhrase(for: status)
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nServer: cocker/\(CockerVersion.version)\r\n\r\n"
        if let data = headers.data(using: .utf8) {
            writeRaw(data)
        }
    }

    /// Response head for a hijacked stream.
    ///
    /// `upgrade` reflects whether the client asked for one: Docker sends
    /// `Connection: Upgrade` / `Upgrade: tcp` and expects `101 UPGRADED`
    /// back, but tolerates a plain 200 when it didn't. Either way the body
    /// that follows is raw.
    func writeHijackHeaders(upgrade: Bool) {
        let head: String
        if upgrade {
            head = "HTTP/1.1 101 UPGRADED\r\n"
                + "Content-Type: application/vnd.docker.raw-stream\r\n"
                + "Connection: Upgrade\r\nUpgrade: tcp\r\n\r\n"
        } else {
            head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/vnd.docker.raw-stream\r\n\r\n"
        }
        writeRaw(Data(head.utf8))
    }

    /// The reason phrase used to be hardcoded to "OK" for every status, so a
    /// streaming 404 went out as `HTTP/1.1 404 OK`.
    static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 101: return "UPGRADED"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default:  return "Status"
        }
    }

    func writeChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        if isRaw { writeRaw(data); return }
        let header = String(format: "%X\r\n", data.count)
        if let h = header.data(using: .utf8) { writeRaw(h) }
        writeRaw(data)
        writeRaw(Data([0x0D, 0x0A]))  // \r\n
    }

    func writeChunk(_ string: String) {
        writeChunk(Data(string.utf8))
    }

    func finish() {
        // A hijacked stream ends by closing the socket, not with a
        // zero-length chunk — writing one would land as literal bytes in
        // the application's output.
        guard !isRaw else { return }
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
        _ = data.writeAll(to: fd)
    }
}

/// Strip Docker's `/v1.NN` API-version prefix, if one is actually there.
///
/// This used to test `path.hasPrefix("/v")` and cut to the next slash, which
/// also matched real endpoints starting with "v": `/volumes/create` became
/// `/create` and 501'd. Any client that omits the version prefix — curl,
/// several SDKs, health probes — lost every `/volumes/*` route.
///
/// Only `/v<major>.<minor>/…` is a version segment.
func stripAPIVersionPrefix(_ path: String) -> String {
    guard path.hasPrefix("/v") else { return path }
    let afterV = path.dropFirst(2)
    guard let slash = afterV.firstIndex(of: "/") else { return path }
    let candidate = afterV[afterV.startIndex..<slash]
    // "1.47" — digits, exactly one dot, digits.
    let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2,
          !parts[0].isEmpty, !parts[1].isEmpty,
          parts.allSatisfy({ $0.allSatisfy(\.isNumber) })
    else { return path }
    return String(afterV[slash...])
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
        if headerData.count > HTTPLimits.maxHeaderBytes { return nil }  // Header too large
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

    path = stripAPIVersionPrefix(path)

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
    if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
        // The real `docker build` streams its context with
        // Transfer-Encoding: chunked and no Content-Length. Only the
        // Content-Length branch existed, so the body came back empty and
        // every build against cocker's socket failed with "Dockerfile not
        // found" — the classic builder path was unusable from the docker CLI.
        guard let decoded = readChunkedBody(from: fd) else { return nil }
        body = decoded
    } else if let lengthStr = headers["content-length"], let length = Int(lengthStr), length > 0 {
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

/// Decode an RFC 7230 chunked body off `fd`.
///
/// Wire shape is a run of `<hex-size>[;ext]\r\n<payload>\r\n` chunks closed by
/// a zero-size chunk and an optional trailer section. Returns nil on a
/// malformed stream or one that exceeds the body cap, so the caller answers
/// with a parse failure instead of acting on a truncated request.
func readChunkedBody(from fd: Int32) -> Data? {
    var body = Data()
    while true {
        guard let sizeLine = readCRLFLine(from: fd) else { return nil }
        // A chunk size may carry `;name=value` extensions we don't use.
        let sizeToken = sizeLine.split(separator: ";", maxSplits: 1)[0]
            .trimmingCharacters(in: .whitespaces)
        guard let size = Int(sizeToken, radix: 16), size >= 0 else { return nil }
        if size == 0 {
            // Trailer section: header lines until a bare CRLF. Discarded —
            // no Docker client sends trailers we act on.
            while let trailer = readCRLFLine(from: fd), !trailer.isEmpty {
                if body.count > HTTPLimits.maxBodyBytes { return nil }
            }
            return body
        }
        guard body.count + size <= HTTPLimits.maxBodyBytes else {
            // The client sees a dropped connection either way, but at least
            // the daemon log says why. A build context larger than the cap
            // needs streaming-to-disk, which this parser doesn't do yet.
            CockerLog.shared.error("docker-api",
                "request body exceeds \(HTTPLimits.maxBodyBytes / 1024 / 1024) MiB cap — "
                + "refusing (a large build context is the usual cause)")
            return nil
        }
        var remaining = size
        while remaining > 0 {
            var buf = [UInt8](repeating: 0, count: min(remaining, 65536))
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            body.append(contentsOf: buf.prefix(n))
            remaining -= n
        }
        // Trailing CRLF after the payload.
        guard readCRLFLine(from: fd) != nil else { return nil }
    }
}

/// Read one CRLF-terminated line, without its terminator. nil on EOF or if
/// the line runs past the header cap.
private func readCRLFLine(from fd: Int32) -> String? {
    var line = Data()
    var byte = [UInt8](repeating: 0, count: 1)
    while true {
        let n = Darwin.read(fd, &byte, 1)
        if n <= 0 { return nil }
        line.append(byte[0])
        if line.suffix(2) == Data([0x0D, 0x0A]) {
            return String(data: line.dropLast(2), encoding: .utf8)
        }
        if line.count > HTTPLimits.maxHeaderBytes { return nil }
    }
}

// MARK: - Helpers

func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
    try? JSONDecoder().decode(type, from: data)
}
