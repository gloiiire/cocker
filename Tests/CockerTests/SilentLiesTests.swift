import Foundation
import Testing
import CockerCore
@testable import CockerCLI

/// Three commands that accepted input and then quietly did something else.
/// Silent wrong behaviour is worse than an unsupported-feature error: the
/// user gets no signal that what they asked for didn't happen.
@Suite("Commands that used to lie")
struct SilentLiesTests {

    // MARK: - context create

    /// `CockerContext.socketPath` returns nil for anything that isn't
    /// `unix://`, and `currentSocketPath` then falls back to the default
    /// socket. So a tcp:// context was accepted, `context use` reported
    /// success, and every command afterwards talked to the *local* daemon.
    @Test func onlyUnixEndpointsAreRoutable() {
        let unix = CockerContext(name: "a", description: "",
                                 dockerHost: "unix:///tmp/x.sock")
        #expect(unix.socketPath == "/tmp/x.sock")

        for unroutable in ["tcp://remote:2376", "ssh://host", "https://host:443", "remote:2376"] {
            let ctx = CockerContext(name: "b", description: "", dockerHost: unroutable)
            #expect(ctx.socketPath == nil, "\(unroutable) should not resolve to a socket")
        }
    }

    @Test func homeIsExpandedInAUnixEndpoint() {
        let ctx = CockerContext(name: "c", description: "", dockerHost: "unix://~/.cocker/cocker.sock")
        #expect(ctx.socketPath?.hasPrefix(NSHomeDirectory()) == true)
        #expect(ctx.socketPath?.contains("~") == false)
    }

    // MARK: - network create

    /// The help advertised `overlay` and the driver was stored, but nothing
    /// implements it — every network behaves as a bridge. A user who asked
    /// for overlay got a bridge and was never told.
    @Test func overlayIsNotAnImplementedDriver() {
        // It still exists in the model (state written by older daemons has to
        // decode), but it is no longer something `network create` accepts.
        #expect(NetworkDriver(rawValue: "overlay") == .overlay)
        for supported in ["bridge", "host", "none"] {
            #expect(NetworkDriver(rawValue: supported) != nil)
        }
        #expect(NetworkDriver(rawValue: "macvlan") == nil)
    }

    @Test func networkLabelsParse() {
        #expect(NetworkCreateCommand.parseLabels(["team=infra", "tier=edge"])
                == ["team": "infra", "tier": "edge"])
        // A bare key records an empty value, as Docker does.
        #expect(NetworkCreateCommand.parseLabels(["standalone"]) == ["standalone": ""])
        // `=` inside the value survives.
        #expect(NetworkCreateCommand.parseLabels(["url=a=b"]) == ["url": "a=b"])
        #expect(NetworkCreateCommand.parseLabels([]).isEmpty)
    }
}
