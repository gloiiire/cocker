import Testing
import Foundation
@testable import CockerDaemon

// Edge cases for `parseHTTPRequest` that the basic suite doesn't exercise.
// Each test wires both ends of a Pipe ; the writer flushes a fixture
// request, the parser reads from the read end's file descriptor.

@Suite("parseHTTPRequest — edge cases")
struct HTTPParserEdgeTests {
    private func parse(_ raw: String) -> HTTPRequest? {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(raw.utf8))
        try? pipe.fileHandleForWriting.close()
        let req = (try? parseHTTPRequest(from: pipe.fileHandleForReading.fileDescriptor)) ?? nil
        try? pipe.fileHandleForReading.close()
        return req
    }

    @Test func queryParamUrlDecodes() {
        let req = parse("GET /containers?name=hello%20world&all=true HTTP/1.1\r\n\r\n")
        #expect(req?.query["name"] == "hello world")
        #expect(req?.query["all"] == "true")
    }

    @Test func emptyQueryValueParses() {
        let req = parse("GET /events?since= HTTP/1.1\r\n\r\n")
        #expect(req?.query["since"] == "")
    }

    @Test func bareFlagInQuery() {
        // `?foo` without `=` should land with empty value.
        let req = parse("GET /containers?foo HTTP/1.1\r\n\r\n")
        #expect(req?.query["foo"] == "")
    }

    @Test func multipleHeadersAccumulate() {
        let req = parse("GET / HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\n\r\n")
        #expect(req?.headers["host"] == "localhost")
        #expect(req?.headers["accept"] == "*/*")
    }

    @Test func contentLengthIsLowercased() {
        // Headers must be case-folded so client variations don't matter.
        let req = parse("POST / HTTP/1.1\r\nContent-Length: 4\r\n\r\ntest")
        #expect(req?.contentLength == 4)
        #expect(req?.body == Data("test".utf8))
    }

    @Test func contentTypeAccessor() {
        let req = parse("POST / HTTP/1.1\r\ncontent-type: application/json\r\n\r\n")
        #expect(req?.contentType == "application/json")
    }

    @Test func missingContentLengthMeansNoBody() {
        let req = parse("GET / HTTP/1.1\r\n\r\n")
        #expect(req?.contentLength == 0)
        #expect(req?.body.isEmpty == true)
    }

    @Test func apiVersionPrefixStripped() {
        let req = parse("GET /v1.47/containers/json HTTP/1.1\r\n\r\n")
        #expect(req?.path == "/containers/json")
    }

    @Test func nonVersionedPathPassesThrough() {
        let req = parse("GET /version HTTP/1.1\r\n\r\n")
        #expect(req?.path == "/version")
    }

    @Test func deleteMethodOK() {
        let req = parse("DELETE /containers/abc HTTP/1.1\r\n\r\n")
        #expect(req?.method == "DELETE")
        #expect(req?.path == "/containers/abc")
    }
}

@Suite("HTTPResponse helpers — payload shapes")
struct HTTPResponseHelperTests {
    @Test func errorWithCustomStatusEncodesMessage() {
        let r = HTTPResponse.error("boom", status: 503)
        #expect(r.status == 503)
        let s = String(data: r.body, encoding: .utf8) ?? ""
        #expect(s.contains("boom"))
    }

    @Test func notFoundIncludesIdInMessage() {
        let r = HTTPResponse.notFound("abc123")
        #expect(r.status == 404)
        let s = String(data: r.body, encoding: .utf8) ?? ""
        #expect(s.contains("abc123"))
    }

    @Test func conflictHas409() {
        #expect(HTTPResponse.conflict("name in use").status == 409)
    }

    @Test func noContentHasNoBody() {
        let r = HTTPResponse.noContent()
        #expect(r.status == 204)
        #expect(r.body.isEmpty)
    }

    @Test func serializedResponseIncludesServerHeader() {
        let r = HTTPResponse(status: 200, headers: ["X-Test": "1"], body: Data("hi".utf8))
        let data = r.serialize()
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("HTTP/1.1 200"))
        #expect(raw.contains("Server: cocker/"))
        #expect(raw.contains("X-Test: 1"))
        #expect(raw.contains("Content-Length: 2"))
        #expect(raw.hasSuffix("\r\n\r\nhi"))
    }
}
