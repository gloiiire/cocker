import Testing
import Foundation
@testable import CockerCore

@Suite("CockerContext — socketPath parsing")
struct CockerContextSocketPathTests {
    @Test func unixPrefixStripped() {
        let c = CockerContext(name: "n", dockerHost: "unix:///var/run/docker.sock")
        #expect(c.socketPath == "/var/run/docker.sock")
    }

    @Test func tildePathExpanded() {
        let c = CockerContext(name: "n", dockerHost: "unix://~/.cocker/cocker.sock")
        #expect(c.socketPath?.contains(NSHomeDirectory()) == true)
        #expect(c.socketPath?.hasSuffix("/.cocker/cocker.sock") == true)
    }

    @Test func tcpHostHasNoSocketPath() {
        let c = CockerContext(name: "n", dockerHost: "tcp://localhost:2375")
        #expect(c.socketPath == nil)
    }

    @Test func defaultIsFalseOnInit() {
        let c = CockerContext(name: "n", dockerHost: "unix:///x")
        #expect(c.isDefault == false)
    }
}

@Suite("ContextStore — current context resolution")
struct ContextStoreCurrentTests {
    @Test func emptyStoreHasNilCurrent() {
        let s = ContextStore()
        #expect(s.currentContext == nil)
        // Falls back to ~/.cocker/cocker.sock when no context resolves.
        #expect(s.currentSocketPath.hasSuffix("/.cocker/cocker.sock"))
    }

    @Test func currentReturnsMatchedContext() {
        var s = ContextStore()
        s.contexts = [
            CockerContext(name: "default", dockerHost: "unix:///a"),
            CockerContext(name: "remote", dockerHost: "tcp://h:2375")
        ]
        s.current = "remote"
        #expect(s.currentContext?.name == "remote")
        #expect(s.currentContext?.dockerHost == "tcp://h:2375")
        // tcp:// context has no socket path → fallback to local default.
        #expect(s.currentSocketPath.hasSuffix("/.cocker/cocker.sock"))
    }

    @Test func loadFromMissingFileReturnsBoot() {
        // Public load() reads $HOME/.cocker/contexts.json ; in CI we
        // don't have one. The store must always include a "default"
        // context (load() injects it if missing).
        let s = ContextStore.load()
        #expect(s.contexts.contains { $0.name == "default" })
    }
}

@Suite("CredentialStore — lookup semantics")
struct CredentialStoreLookupTests {
    @Test func exactHostMatches() {
        var s = CredentialStore()
        s.credentials["ghcr.io"] = .init(username: "alice", password: "pw")
        #expect(s.get(for: "ghcr.io")?.username == "alice")
    }

    @Test func hostPrefixOfFullReferenceFallsBack() {
        var s = CredentialStore()
        s.credentials["ghcr.io"] = .init(username: "alice", password: "pw")
        // Reference like ghcr.io/org/repo:tag — get() strips trailing
        // path segments via components(separatedBy: "/").first.
        #expect(s.get(for: "ghcr.io/org/repo")?.username == "alice")
    }

    @Test func unknownRegistryReturnsNil() {
        let s = CredentialStore()
        #expect(s.get(for: "nope.example.com") == nil)
    }

    @Test func saveAndLoadRoundtrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cocker-cred-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        var s = CredentialStore()
        s.credentials["ghcr.io"] = .init(username: "alice", password: "pw")
        try s.save(to: tmp)
        // 0o600 secrecy contract enforced.
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect(perms == 0o600)
        let back = CredentialStore.load(from: tmp)
        #expect(back.get(for: "ghcr.io")?.password == "pw")
    }

    @Test func loadFromMissingFileReturnsEmpty() {
        let nowhere = URL(fileURLWithPath: "/tmp/cocker-nonexistent-\(UUID().uuidString).json")
        let s = CredentialStore.load(from: nowhere)
        #expect(s.credentials.isEmpty)
    }
}

@Suite("CockerCore.Utils — localHostIP fallback")
struct UtilsLocalHostIPTests {
    @Test func returnsAValidIPv4String() {
        let ip = localHostIP()
        // Either a real LAN IP or the loopback fallback. Both are 4-octet
        // dotted-decimal strings.
        let parts = ip.split(separator: ".")
        #expect(parts.count == 4)
        for p in parts {
            #expect(UInt8(p) != nil)
        }
    }
}
