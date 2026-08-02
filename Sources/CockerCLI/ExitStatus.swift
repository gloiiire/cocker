import Foundation
import CockerCore

/// Carries the exit code out of a streaming IPC handler.
///
/// The daemon reports a finished `exec` as a `.status` event whose payload is
/// `exit:<n>`. Every call site used to `break` on that case, so `cocker exec`
/// and `cocker compose exec` returned 0 no matter what the command did — a
/// script doing `cocker exec c false && deploy` deployed.
///
/// `IPCClient.sendStreaming` takes an `@escaping @Sendable` handler, so the
/// code can't just be captured in a local `var`. This is the minimal box that
/// makes that safe.
final class ExitStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32 = 0

    /// Record the code if `raw` is an `exit:<n>` marker. Returns true when it
    /// consumed the event, so callers know not to also print it as output.
    @discardableResult
    func consume(statusPayload raw: String) -> Bool {
        guard let code = ExitMarker.parse(raw) else { return false }
        lock.lock(); defer { lock.unlock() }
        value = code
        return true
    }

    var code: Int32 {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
