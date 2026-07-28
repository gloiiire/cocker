import Foundation
#if canImport(Darwin)
import Darwin
#endif

// One shared interactive-footer + single-key (d/q) session for every
// terminal-holding command: compose up / watch, run, logs, attach, events,
// daemon logs. Before this existed the codebase had three divergent idioms
// (compose watch's bespoke footer, InteractiveDetach's d-only hint, and
// plain streaming with no keys). Now they all call `InteractiveFooter`.
//
// Charter alignment: the footer is an extension of §8.3's sticky table
// (redraw ≤ every 80ms is handled by UX.StickyView), and §10's off-TTY rule
// is honored — when stdout/stdin isn't a real terminal we degrade to plain
// output and skip raw-mode keys entirely.

/// Puts stdin into cbreak/no-echo so single keystrokes (`d`, `q`) arrive
/// without Enter. Keeps `ISIG` so Ctrl-C still raises SIGINT. `restore()` is
/// idempotent and lock-guarded so the key task and the SIGINT handler can
/// both call it safely.
final class RawMode: @unchecked Sendable {
    private let lock = NSLock()
    private var original = termios()
    private var active = false

    func enter() {
        lock.lock(); defer { lock.unlock() }
        guard !active, isatty(fileno(stdin)) != 0 else { return }
        guard tcgetattr(fileno(stdin), &original) == 0 else { return }
        var raw = original
        raw.c_lflag &= ~(UInt(ICANON) | UInt(ECHO))
        if tcsetattr(fileno(stdin), TCSANOW, &raw) == 0 { active = true }
    }

    func restore() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        _ = tcsetattr(fileno(stdin), TCSANOW, &original)
        active = false
    }
}

/// Collects `service -> URL` pairs for the footer's URL list. Two sources:
///  - `capture(fromStdout:)` scrapes the daemon's
///    " Container <name> Started (id: …)  -> http://localhost:<port>" lines
///    (compose up / watch), buffered since chunks aren't line-aligned.
///  - `add(name:url:)` / `init(pairs:)` for commands that already know their
///    published ports up front (e.g. `run --publish`).
final class ServiceURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [String] = []
    private var map: [String: String] = [:]
    private var buffer = ""

    init() {}

    init(pairs: [(name: String, url: String)]) {
        for p in pairs { order.append(p.name); map[p.name] = p.url }
    }

    func add(name: String, url: String) {
        lock.lock(); defer { lock.unlock() }
        if map[name] == nil { order.append(name) }
        map[name] = url
    }

    func capture(fromStdout chunk: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            parse(String(buffer[buffer.startIndex..<nl]))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
    }

    private func parse(_ line: String) {
        guard let cRange = line.range(of: "Container "),
              let sRange = line.range(of: " Started"),
              let arrow = line.range(of: " -> "),
              cRange.upperBound <= sRange.lowerBound else { return }
        let name = String(line[cRange.upperBound..<sRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let url = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !url.isEmpty else { return }
        if map[name] == nil { order.append(name) }
        map[name] = url
    }

    func snapshot() -> [(name: String, url: String)] {
        lock.lock(); defer { lock.unlock() }
        return order.map { ($0, map[$0] ?? "") }
    }
}

/// Builds a footer block, uniform across commands:
///   <header lines>
///   <one padded "name   url" row per published service>
///   <status lines>
///   press d detach · q quit      (or "press q quit" when !detachable)
/// Callers pass their own (already-painted) header/status lines for flavor;
/// the service-URL rows and the key-hint row are identical everywhere.
func footerLines(header: [String] = [],
                 services: [(name: String, url: String)] = [],
                 status: [String] = [],
                 detach: Bool = false,
                 quit: Bool = false) -> [String] {
    var lines = header
    let width = services.map { $0.name.count }.max() ?? 0
    for s in services {
        let padded = s.name.padding(toLength: max(width, s.name.count), withPad: " ", startingAt: 0)
        lines.append("   " + padded + "   " + UX.TTY.paint(s.url, .accent))
    }
    lines.append(contentsOf: status)
    // Only the keys that actually do something are shown. `d` (detach —
    // leave running) is offered wherever the command holds the terminal ; `q`
    // (quit for real — tear down) only where this command STARTED something.
    // A pure viewer (logs / events) started nothing, so it shows `d` alone.
    var parts: [String] = []
    if detach { parts.append(UX.TTY.paint("d", .accent) + " " + UX.TTY.paint("detach", .dim)) }
    if quit   { parts.append(UX.TTY.paint("q", .accent) + " " + UX.TTY.paint("quit", .dim)) }
    if !parts.isEmpty {
        lines.append("   " + UX.TTY.paint("press", .dim) + " "
            + parts.joined(separator: UX.TTY.paint("   ·   ", .dim)))
    }
    return lines
}

/// A live sticky footer + d/q key session. Enter cbreak, install the SIGINT
/// terminal-restore, spawn a stdin reader that dispatches `d`/`q`. Off-TTY it
/// prints the footer once (plain) and does nothing else. Callers:
///   1. `let f = InteractiveFooter(...)`
///   2. `f.start(...)` once the first footer content is known
///   3. around any scrolling output: `f.clear()` … print … `f.refresh()`
///   4. `f.restore()` on normal completion.
final class InteractiveFooter: @unchecked Sendable {
    /// True only when stdout AND stdin are a real terminal.
    let animated: Bool
    private let raw = RawMode()
    private let sticky = UX.StickyView()
    private let lock = NSLock()
    private var builder: () -> [String] = { [] }

    init() {
        self.animated = UX.TTY.current.animationEnabled && isatty(fileno(stdin)) != 0
    }

    private func currentFooter() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return builder()
    }

    /// Begin the session. `footer` returns the up-to-date footer lines
    /// (re-evaluated on every refresh/re-arm). `onDetach`, if given, runs on
    /// `d` and returns true to exit the process or false to re-arm (used by
    /// compose watch when a detached watch already runs). When `onDetach` is
    /// nil, `d` is ignored and only `q` is offered. `onQuit` runs on `q`
    /// before the process exits.
    func start(footer: @escaping @Sendable () -> [String],
               onDetach: (@Sendable () -> Bool)? = nil,
               onQuit: (@Sendable () async -> Void)? = nil) {
        lock.lock(); builder = footer; lock.unlock()

        guard animated else {
            for l in footer() { print(l) }
            return
        }

        raw.enter()
        sticky.render(footer(), force: true)

        let raw = self.raw
        let sticky = self.sticky
        let build: @Sendable () -> [String] = { [weak self] in self?.currentFooter() ?? [] }

        // Ctrl-C = quit for real (same as `q`): restore cooked mode, run the
        // teardown, then exit. Darwin.exit skips defers, so restore here too.
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sig.setEventHandler {
            raw.restore(); sticky.abandon()
            Task.detached(priority: .userInitiated) {
                if let onQuit { await onQuit() }
                Darwin.exit(0)
            }
        }
        sig.resume()

        Task.detached(priority: .userInitiated) {
            let fd = fileno(stdin)
            var b = [UInt8](repeating: 0, count: 1)
            while read(fd, &b, 1) == 1 {
                switch b[0] {
                case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                    raw.restore(); sticky.abandon()
                    if let onQuit { await onQuit() }
                    Darwin.exit(0)
                case UInt8(ascii: "d"), UInt8(ascii: "D"):
                    guard let onDetach else { break }  // d not offered
                    raw.restore(); sticky.abandon(); print("")
                    if onDetach() { Darwin.exit(0) }
                    // Refused → re-arm keys + footer.
                    raw.enter(); sticky.render(build(), force: true)
                default:
                    break  // ignore; Ctrl-C handled by the kernel via ISIG
                }
            }
        }
    }

    /// For continuously-streaming commands (run, logs, attach, events, daemon
    /// logs): print `lines` (URLs + a `q` hint) ONCE, then arm the `q` key and
    /// the Ctrl-C terminal-restore — but keep NO sticky region, because a
    /// bottom-pinned footer would fight a fast, unbounded log stream. `q` (and
    /// Ctrl-C) restore the terminal and exit; the container/daemon keeps
    /// running (we only detach the viewer). Off-TTY: print once, no keys.
    func armStreaming(_ lines: [String],
                      onDetach: (@Sendable () -> Bool)? = nil,
                      onQuit: (@Sendable () async -> Void)? = nil) {
        // Off-TTY (piped / CI) this is a total no-op — no hint line, no keys —
        // so `logs -f | grep` stays clean.
        guard animated else { return }
        for l in lines { print(l) }
        raw.enter()
        let raw = self.raw
        // Ctrl-C = quit for real (same as `q`): teardown then exit.
        let sig = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sig.setEventHandler {
            raw.restore()
            Task.detached(priority: .userInitiated) {
                if let onQuit { await onQuit() }
                Darwin.exit(0)
            }
        }
        sig.resume()
        Task.detached(priority: .userInitiated) {
            let fd = fileno(stdin)
            var b = [UInt8](repeating: 0, count: 1)
            while read(fd, &b, 1) == 1 {
                switch b[0] {
                case UInt8(ascii: "q"), UInt8(ascii: "Q"):
                    raw.restore()
                    if let onQuit { await onQuit() }
                    Darwin.exit(0)
                case UInt8(ascii: "d"), UInt8(ascii: "D"):
                    guard let onDetach else { break }  // d not offered
                    raw.restore(); print("")
                    if onDetach() { Darwin.exit(0) }
                    raw.enter()  // refused → keep reading keys
                default:
                    break
                }
            }
        }
    }

    /// Erase the footer before printing scrolling output above it.
    func clear() { if animated { sticky.abandon() } }

    /// Re-draw the footer so it's the last thing on screen.
    func refresh() { if animated { sticky.render(currentFooter(), force: true) } }

    /// Restore the terminal on normal completion (no-op if never entered).
    func restore() { raw.restore() }
}
