import Foundation
import Testing
@testable import CockerCore
@testable import CockerDaemon

/// `docker push` resolved its upload target with
/// `URL(string: "\(location)…")!`, where `location` is the `Location` header
/// a remote registry sent back. Any value `URL(string:)` can't parse — a
/// space, a control character, a non-ASCII byte — took the whole daemon down
/// mid-push. Remote input behind a force unwrap.
@Suite("Registry upload Location handling")
struct RegistryUploadLocationTests {

    private let base = URL(string: "https://registry.example.com/v2/app/blobs/uploads/")!
    private let digest = "sha256:abc123"

    @Test func resolvesARelativeLocationAgainstTheRegistry() throws {
        let url = try #require(RegistryClient.uploadPutURL(
            location: "/v2/app/blobs/uploads/uuid-1", base: base, digest: digest))
        #expect(url.absoluteString
            == "https://registry.example.com/v2/app/blobs/uploads/uuid-1?digest=sha256:abc123")
    }

    @Test func keepsAnAbsoluteLocationAsIs() throws {
        let url = try #require(RegistryClient.uploadPutURL(
            location: "https://uploads.example.net/session/9", base: base, digest: digest))
        #expect(url.host == "uploads.example.net")
        #expect(url.absoluteString.hasSuffix("?digest=sha256:abc123"))
    }

    /// Registries commonly hand back a Location that already carries query
    /// state (`_state=` on Docker Distribution), so the digest has to be
    /// appended, not started.
    @Test func appendsToAnExistingQueryString() throws {
        let url = try #require(RegistryClient.uploadPutURL(
            location: "/v2/app/blobs/uploads/uuid-1?_state=xyz", base: base, digest: digest))
        #expect(url.absoluteString.contains("_state=xyz&digest=sha256:abc123"))
    }

    @Test func preservesANonDefaultPort() throws {
        let local = URL(string: "http://localhost:5000/v2/app/blobs/uploads/")!
        let url = try #require(RegistryClient.uploadPutURL(
            location: "/v2/app/blobs/uploads/uuid-1", base: local, digest: digest))
        #expect(url.absoluteString.hasPrefix("http://localhost:5000/"))
    }

    @Test func toleratesALocationMissingItsLeadingSlash() throws {
        let url = try #require(RegistryClient.uploadPutURL(
            location: "v2/app/blobs/uploads/uuid-1", base: base, digest: digest))
        #expect(url.path == "/v2/app/blobs/uploads/uuid-1")
    }

    // MARK: - The crash

    /// The inputs that used to kill cockerd. `URL(string:)` returning nil was
    /// behind a `!`, so a registry could take the daemon down by answering
    /// with a Location it couldn't parse. Returning nil lets the caller raise
    /// a normal push failure instead.
    ///
    /// Note how narrow the set is: current Foundation percent-encodes most
    /// junk (see `encodesRatherThanRejectsLooseCharacters`) rather than
    /// failing, so this was reachable mainly through a malformed authority —
    /// and that leniency is a Foundation version detail, not a guarantee.
    @Test func unparseableLocationsAreRejectedNotCrashed() {
        let hostile = [
            "",                            // header present but empty
            "http://[not-a-host/uploads",  // malformed authority
        ]
        for location in hostile {
            #expect(RegistryClient.uploadPutURL(location: location, base: base, digest: digest) == nil,
                    "should have refused: \(location.debugDescription)")
        }
    }

    /// Loose characters are encoded, not rejected — asserted so a Foundation
    /// change that starts returning nil here shows up as a failure rather
    /// than as a push that dies in the field.
    @Test func encodesRatherThanRejectsLooseCharacters() throws {
        let spaced = try #require(RegistryClient.uploadPutURL(
            location: "/v2/app/blobs/uploads/has space", base: base, digest: digest))
        #expect(spaced.absoluteString.contains("has%20space"))

        let control = try #require(RegistryClient.uploadPutURL(
            location: "/v2/app/uploads/\u{7F}", base: base, digest: digest))
        #expect(control.absoluteString.contains("%7F"))
    }

    @Test func rejectsARelativeLocationWhenTheBaseHasNoHost() {
        let hostless = URL(string: "file:///tmp/whatever")!
        #expect(RegistryClient.uploadPutURL(location: "/uploads/1", base: hostless, digest: digest) == nil)
    }
}

/// The exec stream is backed by a blocking vsock read on a GCD worker. It has
/// to be able to notice that its consumer went away, or the worker parks for
/// the daemon's lifetime and enough of them exhaust the global pool.
@Suite("Exec stream lifetime")
struct ExecStreamLifetimeTests {

    @Test func startsLive() {
        #expect(!ExecStreamLifetime().isCancelled)
    }

    @Test func cancelIsObservable() {
        let lifetime = ExecStreamLifetime()
        lifetime.cancel()
        #expect(lifetime.isCancelled)
    }

    /// Registering after cancellation must be refused, so a connection that
    /// lands late is torn down instead of streaming into a dead consumer.
    @Test func refusesRegistrationAfterCancel() {
        let lifetime = ExecStreamLifetime()
        lifetime.cancel()
        let fds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { fds.deallocate() }
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(lifetime.register(fd: fds[0]) == false)
    }

    @Test func acceptsRegistrationWhileLive() {
        let lifetime = ExecStreamLifetime()
        let fds = UnsafeMutablePointer<Int32>.allocate(capacity: 2)
        defer { fds.deallocate() }
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        #expect(lifetime.register(fd: fds[0]) == true)
        lifetime.complete()
    }

    /// The connect deadline and the connect callback race from different
    /// queues; exactly one of them may close the stream.
    @Test func onlyOneClaimantWins() {
        let box = ResumeOnceBox()
        #expect(box.tryClaim() == true)
        #expect(box.tryClaim() == false)
        #expect(box.tryClaim() == false)
    }

    /// A bounded connect timeout is the whole point — an unbounded one is
    /// what let `cocker exec` hang forever when the framework callback never
    /// fired.
    @Test func connectTimeoutIsBounded() {
        #expect(VMRuntime.execConnectTimeout > 0)
        #expect(VMRuntime.execConnectTimeout <= 60)
    }
}
