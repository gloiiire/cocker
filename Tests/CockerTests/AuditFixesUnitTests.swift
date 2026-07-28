import Testing
import Foundation
import Darwin
@testable import CockerCore

// Unit tests for the pure helpers introduced by the 0.6.0 audit. Each
// helper sits behind a real correctness contract (path traversal, secret
// redaction, env typo guards) so the absence of coverage would be the
// outage waiting to happen.

@Suite("PathConfinement — lexical escape guard")
struct PathConfinementLexicalTests {
    private func makeRoot() -> URL {
        URL(fileURLWithPath: "/tmp/cocker-test-root")
    }

    @Test func plainRelativeStaysUnderRoot() throws {
        let root = makeRoot()
        let r = try PathConfinement.confine("etc/passwd", to: root)
        #expect(r.path == "/tmp/cocker-test-root/etc/passwd")
    }

    @Test func leadingSlashIsStripped() throws {
        let root = makeRoot()
        let r = try PathConfinement.confine("/etc/passwd", to: root)
        #expect(r.path == "/tmp/cocker-test-root/etc/passwd")
    }

    @Test func dotDotEscapeRefused() throws {
        let root = makeRoot()
        #expect(throws: CockerError.self) {
            _ = try PathConfinement.confine("../etc/passwd", to: root)
        }
    }

    @Test func deepDotDotEscapeRefused() throws {
        let root = makeRoot()
        #expect(throws: CockerError.self) {
            _ = try PathConfinement.confine("etc/../../../../etc/passwd", to: root)
        }
    }

    @Test func dotDotInsideRootIsResolved() throws {
        let root = makeRoot()
        let r = try PathConfinement.confine("a/b/../c", to: root)
        #expect(r.path == "/tmp/cocker-test-root/a/c")
    }

    @Test func currentDirSegmentsCollapse() throws {
        let root = makeRoot()
        let r = try PathConfinement.confine("./a/./b", to: root)
        #expect(r.path == "/tmp/cocker-test-root/a/b")
    }

    @Test func emptyPathReturnsRoot() throws {
        let root = makeRoot()
        let r = try PathConfinement.confine("", to: root)
        #expect(r.path == root.path)
    }

    @Test func nulByteRejected() throws {
        let root = makeRoot()
        // POSIX filenames forbid NUL ; without the explicit check Foundation
        // would truncate at the NUL and a "/etc\0/../escape" payload could
        // slip past the lexical guard.
        #expect(throws: CockerError.self) {
            _ = try PathConfinement.confine("etc\0/../escape", to: root)
        }
    }
}

@Suite("Unix socket address validation")
struct UnixSocketAddressTests {
    @Test func preservesValidPathExactly() throws {
        let path = "/tmp/cocker-test.sock"
        var address = try makeUnixSocketAddress(path: path)
        let decoded = withUnsafePointer(to: &address.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #expect(decoded == path)
    }

    @Test func rejectsPathThatWouldBeTruncated() {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        let path = "/" + String(repeating: "x", count: capacity)
        #expect(throws: Error.self) { try makeUnixSocketAddress(path: path) }
    }
}

@Suite("PathConfinement — read flavour follows symlinks")
struct PathConfinementReadTests {
    @Test func resolvesToExistingFileInsideRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-confine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: payload)

        let resolved = try PathConfinement.confineRead("a.txt", to: root)
        #expect(resolved.path.hasPrefix(root.resolvingSymlinksInPath().path))
    }

    @Test func refusesSymlinkPointingOutsideRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cocker-confine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideTarget = URL(fileURLWithPath: "/etc/hosts")
        let bait = root.appendingPathComponent("sneaky")
        try FileManager.default.createSymbolicLink(
            at: bait, withDestinationURL: outsideTarget)

        #expect(throws: CockerError.self) {
            _ = try PathConfinement.confineRead("sneaky", to: root)
        }
    }
}

@Suite("SecretRedactor — key heuristics")
struct SecretRedactorTests {
    @Test func sensitiveKeysAreReplaced() {
        let env = [
            "DB_PASSWORD": "p4ssw0rd",
            "API_TOKEN":   "secret-token-123",
            "PATH":        "/usr/bin",
            "HOME":        "/tmp",
        ]
        let r = SecretRedactor.redact(env)
        #expect(r["DB_PASSWORD"] == "***")
        #expect(r["API_TOKEN"] == "***")
        #expect(r["PATH"] == "/usr/bin")
        #expect(r["HOME"] == "/tmp")
    }

    @Test func customReplacementHonoured() {
        let r = SecretRedactor.redact(["SECRET": "x"], replacement: "[REDACTED]")
        #expect(r["SECRET"] == "[REDACTED]")
    }

    @Test func isSensitiveMatchesSubstrings() {
        #expect(SecretRedactor.isSensitive("MY_SECRET_THING"))
        #expect(SecretRedactor.isSensitive("aws_access_token"))
        #expect(SecretRedactor.isSensitive("PRIVATE_KEY"))
        #expect(!SecretRedactor.isSensitive("HOSTNAME"))
        #expect(!SecretRedactor.isSensitive("PATH"))
    }

    @Test func redactedForDisplayMasksContainerEnv() {
        let c = Container(
            name: "demo",
            image: "alpine",
            command: ["sh"],
            env: ["DB_PASSWORD": "topsecret", "FOO": "bar"]
        )
        let masked = c.redactedForDisplay()
        #expect(masked.env["DB_PASSWORD"] == "***")
        #expect(masked.env["FOO"] == "bar")
        // Original instance is untouched (Container is a value type).
        #expect(c.env["DB_PASSWORD"] == "topsecret")
    }
}

@Suite("CockerEnv — typed environment access")
struct CockerEnvTests {
    @Test func rawValueMatchesExpectedKey() {
        #expect(CockerEnv.cockerHost.rawValue == "COCKER_HOST")
        #expect(CockerEnv.logLevel.rawValue == "COCKER_LOG_LEVEL")
        #expect(CockerEnv.tcpTLSPort.rawValue == "COCKER_TCP_TLS_PORT")
    }

    @Test func allCasesCovered() {
        // CaseIterable conformance gives us a compile-time safety net : if
        // someone adds a new env var they need to wire it into one of the
        // call sites, and this count ratchet flags the addition.
        #expect(CockerEnv.allCases.count == 8)
    }

    @Test func stringValueReadsProcessEnv() {
        // setenv lets us mutate the live environ that ProcessInfo reads from ;
        // unsetenv after to keep tests hermetic. Foundation's
        // ProcessInfo.processInfo.environment recomputes from environ on
        // each access (no cache), so the test sees the override immediately.
        setenv("COCKER_HOST", "unix:///tmp/cocker-test.sock", 1)
        defer { unsetenv("COCKER_HOST") }
        #expect(CockerEnv.cockerHost.stringValue == "unix:///tmp/cocker-test.sock")
    }

    @Test func boolValueParsesCommonTruthy() {
        let key = "COCKER_REDACT_INSPECT"
        for raw in ["1", "true", "YES", "on"] {
            setenv(key, raw, 1)
            #expect(CockerEnv.redactInspect.boolValue)
        }
        for raw in ["", "0", "nope", "false"] {
            setenv(key, raw, 1)
            #expect(!CockerEnv.redactInspect.boolValue)
        }
        unsetenv(key)
        #expect(!CockerEnv.redactInspect.boolValue)
    }

    @Test func intValueParsesNumeric() {
        setenv("COCKER_DNS_PORT", "5353", 1)
        defer { unsetenv("COCKER_DNS_PORT") }
        #expect(CockerEnv.dnsPort.intValue == 5353)
        setenv("COCKER_DNS_PORT", "not-a-number", 1)
        #expect(CockerEnv.dnsPort.intValue == nil)
    }
}

@Suite("InspectResponse DTO redaction")
struct InspectResponseTests {
    @Test func redactsSecretsByDefault() {
        let c = Container(
            name: "web",
            image: "nginx",
            command: ["/usr/sbin/nginx"],
            env: ["DB_PASSWORD": "shh", "PORT": "80"]
        )
        let dto = InspectResponse(from: c)
        #expect(dto.env["DB_PASSWORD"] == "***")
        #expect(dto.env["PORT"] == "80")
    }

    @Test func passThroughWhenRedactionDisabled() {
        let c = Container(
            name: "web",
            image: "nginx",
            command: ["/usr/sbin/nginx"],
            env: ["DB_PASSWORD": "shh"]
        )
        let dto = InspectResponse(from: c, redactSecrets: false)
        #expect(dto.env["DB_PASSWORD"] == "shh")
    }

    @Test func carriesIdentityAndLifecycleFields() {
        let c = Container(
            id: "abcdef012345",
            name: "n",
            image: "i",
            command: ["c"],
            ports: [PortMapping(hostPort: 8080, containerPort: 80)],
            restartPolicy: .always
        )
        let dto = InspectResponse(from: c)
        #expect(dto.id == "abcdef012345")
        #expect(dto.name == "n")
        #expect(dto.image == "i")
        #expect(dto.command == ["c"])
        #expect(dto.ports.first?.hostPort == 8080)
        #expect(dto.restartPolicy == .always)
    }
}

@Suite("IPC protocol versioning")
struct IPCVersionTests {
    @Test func currentRequestSendsCurrentVersion() throws {
        let req = try IPCRequest(type: .ping, payload: EmptyPayload())
        #expect(req.protocolVersion == CockerVersion.ipcProtocolVersion)
    }

    @Test func legacyRequestWithoutVersionDecodes() throws {
        let legacyJSON =
            #"""
            {"id":"abc","type":"ping","payload":""}
            """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: legacyJSON)
        #expect(decoded.protocolVersion == nil)
        #expect(decoded.id == "abc")
    }
}
