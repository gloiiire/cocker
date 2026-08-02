import Foundation
import Testing
@testable import CockerDaemon

/// Docker hijacks `/attach` and `/exec/{id}/start`: after the response head
/// the Go client stops speaking HTTP and reads the socket directly. Cocker
/// answered both with `Transfer-Encoding: chunked`, so chunk-size lines
/// landed *inside* the stdcopy stream — clients saw "unrecognized input
/// header" or silently corrupted output.
@Suite("Docker hijacked streams")
struct DockerHijackTests {

    private func capture(_ body: (HTTPStreamWriter) -> Void) -> Data {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress) }
        #expect(rc == 0)
        var writer = HTTPStreamWriter(fd: fds[0])
        writer.isRaw = true
        body(writer)
        close(fds[0])
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fds[1], &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf.prefix(n))
        }
        close(fds[1])
        return out
    }

    // MARK: - Upgrade negotiation

    private func request(headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/containers/x/attach", query: [:],
                    headers: headers, body: Data())
    }

    @Test func detectsTheUpgradeHandshake() {
        #expect(DockerAPIServer.wantsUpgrade(request(headers: ["upgrade": "tcp"])))
        #expect(DockerAPIServer.wantsUpgrade(request(headers: ["connection": "Upgrade"])))
        #expect(DockerAPIServer.wantsUpgrade(
            request(headers: ["connection": "Upgrade", "upgrade": "tcp"])))
    }

    /// Older clients just POST and read the body; answering 101 to those
    /// would strand them.
    @Test func plainRequestsAreNotUpgraded() {
        #expect(!DockerAPIServer.wantsUpgrade(request(headers: [:])))
        #expect(!DockerAPIServer.wantsUpgrade(request(headers: ["connection": "close"])))
    }

    // MARK: - Response head

    @Test func upgradedHeadIsWhatDockerExpects() {
        let text = String(decoding: capture { $0.writeHijackHeaders(upgrade: true) }, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 101 UPGRADED\r\n"))
        #expect(text.contains("Content-Type: application/vnd.docker.raw-stream"))
        #expect(text.contains("Upgrade: tcp"))
        // The one thing that must never appear on a hijacked stream.
        #expect(!text.contains("Transfer-Encoding"))
    }

    @Test func nonUpgradedHeadIsAPlain200RawStream() {
        let text = String(decoding: capture { $0.writeHijackHeaders(upgrade: false) }, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("application/vnd.docker.raw-stream"))
        #expect(!text.contains("Transfer-Encoding"))
    }

    // MARK: - Raw body

    @Test func rawModeWritesBytesUntouched() {
        let payload = Data("hello world".utf8)
        #expect(capture { $0.writeChunk(payload) } == payload)
    }

    /// A zero-length chunk terminator on a raw stream lands as literal bytes
    /// in the application's output.
    @Test func rawModeDoesNotWriteAChunkTerminator() {
        #expect(capture { $0.finish() }.isEmpty)
    }

    /// stdcopy framing: 8-byte header, stream id first, big-endian length in
    /// bytes 4–7 — and no chunk-size line wrapped around it.
    @Test func logFramesKeepTheirStdcopyHeader() {
        let out = capture { $0.writeLogFrame(stream: 2, data: Data("err".utf8)) }
        #expect(out.count == 11)
        #expect(out[0] == 2)                       // stderr
        #expect(Array(out[4..<8]) == [0, 0, 0, 3]) // length
        #expect(String(decoding: out[8...], as: UTF8.self) == "err")
    }

    // MARK: - Status lines

    /// Every streaming response used the literal reason phrase "OK", so a
    /// streaming 404 went out as `HTTP/1.1 404 OK`.
    @Test func reasonPhrasesMatchTheirStatus() {
        #expect(HTTPStreamWriter.reasonPhrase(for: 200) == "OK")
        #expect(HTTPStreamWriter.reasonPhrase(for: 101) == "UPGRADED")
        #expect(HTTPStreamWriter.reasonPhrase(for: 404) == "Not Found")
        #expect(HTTPStreamWriter.reasonPhrase(for: 500) == "Internal Server Error")
    }
}
