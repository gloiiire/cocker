import Foundation

// Cocker UX charter §9 — log streaming UX. Two pieces :
//   1. paint(stream:) — colors a single line based on whether it came
//      from stdout (default) or stderr (red, dim).
//   2. ComposePrefixer — stable per-service color rotation, padded to
//      the widest active service name, used by `cocker compose logs`.
//
// Service colors come from an 8-entry palette and are picked by hashing
// the service name. The hash is FNV-1a 32-bit so it's stable across
// processes (vs. Swift's Hasher which is seeded per-run).

public extension UX {
    enum StreamKind: Sendable {
        case stdout, stderr
    }

    enum Stream {
        public static func paint(_ line: String, stream: StreamKind) -> String {
            switch stream {
            case .stdout: return line
            case .stderr: return UX.TTY.paint(line, .failure, [.dim])
            }
        }

        // 8 named colors (charter §9.2). Each service is assigned one
        // deterministically by hashing its name — same name → same color
        // across runs, restarts, and processes.
        public static let servicePalette: [Color] = [
            .progress,  // cyan
            .accent,    // magenta
            .success,   // green
            .warn,      // yellow
            .restart,   // (alias of yellow — kept so palette stays 8 wide)
            .failure,   // red
            .dim,       // gray
            .default,   // plain
        ]

        public static func serviceColor(for name: String) -> Color {
            let h = fnv1a32(name)
            return servicePalette[Int(h % UInt32(servicePalette.count))]
        }

        // FNV-1a 32-bit. Stable, fast, no external deps. Cryptographic
        // strength not needed — we just want consistent colors.
        public static func fnv1a32(_ s: String) -> UInt32 {
            var h: UInt32 = 0x811C9DC5
            for byte in s.utf8 {
                h ^= UInt32(byte)
                h = h &* 0x01000193
            }
            return h
        }
    }

    final class ComposePrefixer: @unchecked Sendable {
        private let lock = NSLock()
        private var widthSeen = 0
        private var seen = Set<String>()

        public init(initialServices: [String] = []) {
            for s in initialServices { observe(s) }
        }

        // Register a service name so the prefix column can grow to fit.
        // Call once per service before the first render() for that service.
        public func observe(_ service: String) {
            lock.lock(); defer { lock.unlock() }
            seen.insert(service)
            if service.count > widthSeen { widthSeen = service.count }
        }

        // Render a single log line with the service prefix. `stream`
        // affects coloring of the BODY (stderr dim red), not the prefix.
        public func render(service: String, stream: StreamKind, line: String) -> String {
            lock.lock()
            if !seen.contains(service) {
                seen.insert(service)
                if service.count > widthSeen { widthSeen = service.count }
            }
            let w = widthSeen
            lock.unlock()

            let padded = service.padding(toLength: w, withPad: " ", startingAt: 0)
            let coloredPrefix = UX.TTY.paint(padded, UX.Stream.serviceColor(for: service))
            let body = UX.Stream.paint(line, stream: stream)
            let sep = UX.TTY.paint("|", .dim)
            return "\(coloredPrefix) \(sep) \(body)"
        }
    }
}
