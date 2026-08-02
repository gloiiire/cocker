import Foundation
import Testing
@testable import CockerDaemon

/// Three defects that made correct clients fail on well-formed requests.
@Suite("Chunked bodies and route resolution")
struct HTTPChunkedAndRoutingTests {

    /// Feed a raw request through the real parser over a socketpair, exactly
    /// as the accept loop would.
    private func parse(_ raw: String) throws -> HTTPRequest? {
        var fds: [Int32] = [-1, -1]
        let rc = fds.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress) }
        #expect(rc == 0)
        defer { close(fds[1]) }
        let bytes = [UInt8](raw.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fds[0], $0.baseAddress, $0.count) }
        close(fds[0])
        return try parseHTTPRequest(from: fds[1])
    }

    // MARK: - Chunked request bodies

    /// The real `docker build` streams its context chunked with no
    /// Content-Length. Only the Content-Length branch existed, so the body
    /// arrived empty and every build failed with "Dockerfile not found".
    @Test func decodesAChunkedBody() throws {
        let raw = "POST /v1.47/build HTTP/1.1\r\n"
            + "Host: docker\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n"
            + "6\r\n world\r\n"
            + "0\r\n\r\n"
        let req = try #require(try parse(raw))
        #expect(String(data: req.body, encoding: .utf8) == "hello world")
        #expect(req.path == "/build")
    }

    @Test func handlesChunkExtensionsAndTrailers() throws {
        let raw = "POST /v1.47/build HTTP/1.1\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n"
            + "4;name=value\r\ndata\r\n"
            + "0\r\n"
            + "X-Checksum: abc\r\n\r\n"
        let req = try #require(try parse(raw))
        #expect(String(data: req.body, encoding: .utf8) == "data")
    }

    @Test func anEmptyChunkedBodyIsValid() throws {
        let raw = "POST /v1.47/build HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        let req = try #require(try parse(raw))
        #expect(req.body.isEmpty)
    }

    /// A truncated stream must fail to parse rather than hand a half-read
    /// build context to the builder.
    @Test func rejectsATruncatedChunkedBody() throws {
        let raw = "POST /v1.47/build HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n10\r\nshort"
        #expect(try parse(raw) == nil)
    }

    @Test func rejectsAMalformedChunkSize() throws {
        let raw = "POST /v1.47/build HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nxx\r\n0\r\n\r\n"
        #expect(try parse(raw) == nil)
    }

    /// Content-Length still works — chunked is an added branch, not a
    /// replacement.
    @Test func contentLengthBodiesStillParse() throws {
        let raw = "POST /v1.47/containers/create HTTP/1.1\r\n"
            + "Content-Length: 13\r\n\r\n"
            + #"{"Image":"x"}"#
        let req = try #require(try parse(raw))
        #expect(String(data: req.body, encoding: .utf8) == #"{"Image":"x"}"#)
    }

    // MARK: - API version prefix

    @Test func stripsARealVersionPrefix() {
        #expect(stripAPIVersionPrefix("/v1.47/containers/json") == "/containers/json")
        #expect(stripAPIVersionPrefix("/v1.41/volumes") == "/volumes")
    }

    /// The old check was `hasPrefix("/v")` + cut to the next slash, so
    /// `/volumes/create` became `/create` and 501'd. Any client that omits
    /// the version prefix lost every `/volumes/*` route.
    @Test func doesNotEatPathsThatMerelyStartWithV() {
        #expect(stripAPIVersionPrefix("/volumes/create") == "/volumes/create")
        #expect(stripAPIVersionPrefix("/volumes") == "/volumes")
        #expect(stripAPIVersionPrefix("/version") == "/version")
    }

    @Test func leavesNonVersionSegmentsAlone() {
        #expect(stripAPIVersionPrefix("/vfoo/bar") == "/vfoo/bar")
        #expect(stripAPIVersionPrefix("/v1/bar") == "/v1/bar")      // no minor
        #expect(stripAPIVersionPrefix("/v1.2.3/bar") == "/v1.2.3/bar")
    }

    @Test func unversionedVolumeRoutesSurviveParsing() throws {
        let raw = "POST /volumes/create HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"
        let req = try #require(try parse(raw))
        #expect(req.path == "/volumes/create")
    }

    // MARK: - Registry-qualified image names

    /// `/images/ghcr.io/org/app/json` splits into five segments, so the old
    /// `segments.count == 3` guards missed and every namespaced reference
    /// fell through to the 501 default.
    @Test func rebuildsAQualifiedImageName() {
        #expect(DockerAPIServer.imageName(from: ["images", "ghcr.io", "org", "app", "json"])
                == "ghcr.io/org/app")
        #expect(DockerAPIServer.imageName(from: ["images", "library", "redis", "json"])
                == "library/redis")
        #expect(DockerAPIServer.imageName(from: ["images", "nginx", "json"]) == "nginx")
    }

    /// DELETE has no trailing verb — the last segment is part of the name.
    @Test func handlesRoutesWithoutAVerbSuffix() {
        #expect(DockerAPIServer.imageName(from: ["images", "ghcr.io", "org", "app"],
                                          hasVerbSuffix: false) == "ghcr.io/org/app")
        #expect(DockerAPIServer.imageName(from: ["images", "nginx"], hasVerbSuffix: false) == "nginx")
    }

    /// Some clients percent-encode the slashes instead of sending them raw.
    @Test func decodesAPercentEncodedName() {
        #expect(DockerAPIServer.imageName(from: ["images", "ghcr.io%2Forg%2Fapp", "json"])
                == "ghcr.io/org/app")
    }

    @Test func toleratesAMissingName() {
        #expect(DockerAPIServer.imageName(from: ["images", "json"]) == "")
        #expect(DockerAPIServer.imageName(from: ["images"], hasVerbSuffix: false) == "")
    }
}
