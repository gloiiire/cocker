import Testing
import Foundation
import Darwin
@testable import CockerCore
@testable import CockerDaemon

@Suite("HTTPResponse — constructors")
struct HTTPResponseConstructorTests {
    @Test func defaultInit() {
        let r = HTTPResponse()
        #expect(r.status == 200)
        #expect(r.statusText == "OK")
        #expect(r.body.isEmpty)
    }

    @Test func customInit() {
        let r = HTTPResponse(status: 418, statusText: "I'm a teapot",
                             headers: ["X-Custom": "value"],
                             body: Data("body".utf8))
        #expect(r.status == 418)
        #expect(r.statusText == "I'm a teapot")
        #expect(r.headers["X-Custom"] == "value")
        #expect(r.body == Data("body".utf8))
    }

    @Test func jsonHelperSetsContentType() {
        struct Payload: Encodable { let foo: String }
        let r = HTTPResponse.json(Payload(foo: "bar"))
        #expect(r.status == 200)
        #expect(r.headers["Content-Type"] == "application/json")
        #expect(String(data: r.body, encoding: .utf8)!.contains("\"foo\""))
    }

    @Test func jsonHelperPassesThroughStatus() {
        struct P: Encodable { let n: Int }
        let r = HTTPResponse.json(P(n: 42), status: 201)
        #expect(r.status == 201)
    }

    @Test func errorHelperHas500Default() {
        let r = HTTPResponse.error("something broke")
        #expect(r.status == 500)
        #expect(String(data: r.body, encoding: .utf8)!.contains("something broke"))
    }

    @Test func errorHelperWithCustomStatus() {
        let r = HTTPResponse.error("forbidden", status: 403)
        #expect(r.status == 403)
    }

    @Test func noContentHelper() {
        let r = HTTPResponse.noContent()
        #expect(r.status == 204)
        #expect(r.statusText == "No Content")
    }

    @Test func notFoundHelperIncludesID() {
        let r = HTTPResponse.notFound("abc123")
        #expect(r.status == 404)
        #expect(String(data: r.body, encoding: .utf8)!.contains("abc123"))
    }

    @Test func conflictHelper() {
        let r = HTTPResponse.conflict("name in use")
        #expect(r.status == 409)
        #expect(String(data: r.body, encoding: .utf8)!.contains("name in use"))
    }
}

@Suite("HTTPResponse — serialization")
struct HTTPResponseSerializeTests {
    @Test func includesStatusLine() {
        let r = HTTPResponse(status: 200)
        let raw = String(data: r.serialize(), encoding: .utf8) ?? ""
        #expect(raw.contains("HTTP/1.1 200 OK"))
    }

    @Test func includesServerHeader() {
        let r = HTTPResponse()
        let raw = String(data: r.serialize(), encoding: .utf8) ?? ""
        #expect(raw.contains("Server: cocker/"))
    }

    @Test func includesContentLength() {
        let body = "hello world"
        let r = HTTPResponse(body: Data(body.utf8))
        let raw = String(data: r.serialize(), encoding: .utf8) ?? ""
        #expect(raw.contains("Content-Length: \(body.count)"))
    }

    @Test func includesCustomHeaders() {
        let r = HTTPResponse(headers: ["X-Foo": "bar", "X-Baz": "qux"])
        let raw = String(data: r.serialize(), encoding: .utf8) ?? ""
        #expect(raw.contains("X-Foo: bar"))
        #expect(raw.contains("X-Baz: qux"))
    }

    @Test func appendsBody() {
        let body = "the actual body"
        let r = HTTPResponse(body: Data(body.utf8))
        let raw = String(data: r.serialize(), encoding: .utf8) ?? ""
        #expect(raw.hasSuffix(body))
    }

    @Test func headerSeparator() {
        let r = HTTPResponse(body: Data("x".utf8))
        let raw = String(data: r.serialize(), encoding: .utf8) ?? ""
        // \r\n\r\n marks end of headers
        #expect(raw.contains("\r\n\r\n"))
    }
}

@Suite("parseHTTPRequest — integration via pipe")
struct HTTPParserPipeTests {
    /// Build a Unix pipe, feed `payload` into the write side, parse from the
    /// read side. Returns the parsed request (or nil) without crashing if the
    /// helpers misbehave.
    private func parse(_ payload: String) -> HTTPRequest? {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return nil }
        let r = fds[0]
        let w = fds[1]

        let data = Data(payload.utf8)
        data.withUnsafeBytes { buf in
            _ = Darwin.write(w, buf.baseAddress, buf.count)
        }
        close(w)

        let req = try? parseHTTPRequest(from: r)
        close(r)
        return req
    }

    @Test func parsesGETLine() {
        let req = parse("GET /v1.41/containers/json HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(req?.method == "GET")
    }

    @Test func stripsAPIVersionPrefix() {
        let req = parse("GET /v1.41/containers/json HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(req?.path == "/containers/json")
    }

    @Test func parsesQueryString() {
        let req = parse("GET /v1.41/containers/json?all=true&size=100 HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(req?.query["all"] == "true")
        #expect(req?.query["size"] == "100")
    }

    @Test func parsesValueLessQueryKey() {
        let req = parse("GET /v1.41/containers/json?stream HTTP/1.1\r\nHost: localhost\r\n\r\n")
        #expect(req?.query["stream"] == "")
    }

    @Test func parsesHeaders() {
        let req = parse("POST /v1.41/containers/create HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nX-Auth: token\r\n\r\n")
        #expect(req?.headers["host"] == "localhost")
        #expect(req?.headers["content-type"] == "application/json")
        #expect(req?.headers["x-auth"] == "token")
    }

    @Test func readsBodyWithContentLength() {
        let body = "{\"name\":\"x\"}"
        let req = parse("POST /v1.41/containers/create HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.count)\r\n\r\n\(body)")
        #expect(req?.body == Data(body.utf8))
    }

    @Test func parsesMethodsBesideGET() {
        for verb in ["POST", "PUT", "DELETE", "HEAD"] {
            let req = parse("\(verb) /v1.41/x HTTP/1.1\r\nHost: x\r\n\r\n")
            #expect(req?.method == verb)
        }
    }

    @Test func percentDecodedQueryValues() {
        let req = parse("GET /v1.41/x?filter=name%3Dweb HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(req?.query["filter"] == "name=web")
    }

    @Test func contentTypeAccessor() {
        let req = parse("POST /v1.41/x HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n\r\n")
        #expect(req?.contentType == "application/json")
    }

    @Test func contentLengthAccessor() {
        let req = parse("POST /v1.41/x HTTP/1.1\r\nHost: x\r\nContent-Length: 42\r\n\r\n")
        #expect(req?.contentLength == 42)
    }

    @Test func contentLengthZeroWhenAbsent() {
        let req = parse("GET /v1.41/x HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(req?.contentLength == 0)
    }
}

@Suite("HTTPMethod enum")
struct HTTPMethodTests {
    @Test func recognisedMethods() {
        for m in ["GET", "POST", "PUT", "DELETE", "HEAD", "OPTIONS", "PATCH"] {
            #expect(HTTPMethod(rawValue: m) != nil)
        }
    }
}

@Suite("decodeJSON helper")
struct DecodeJSONHelperTests {
    struct Payload: Codable, Equatable { let id: Int; let name: String }

    @Test func decodesValidJSON() {
        let raw = Data("{\"id\":7,\"name\":\"x\"}".utf8)
        let p: Payload? = decodeJSON(Payload.self, from: raw)
        #expect(p == Payload(id: 7, name: "x"))
    }

    @Test func returnsNilOnGarbage() {
        let raw = Data("not json".utf8)
        let p: Payload? = decodeJSON(Payload.self, from: raw)
        #expect(p == nil)
    }

    @Test func returnsNilOnEmpty() {
        let p: Payload? = decodeJSON(Payload.self, from: Data())
        #expect(p == nil)
    }
}
