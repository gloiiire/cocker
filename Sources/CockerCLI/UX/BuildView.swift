import CockerCore
import Foundation

// Cocker UX charter §8.3 + §13.3 — BuildKit-style sticky build view.
// Wraps a StickyView and consumes the daemon's build event stream
// (`Step N/M : KEYWORD args`, ` ---> Using cache (layer ...)`,
// `Successfully built <hash>`...) into a redraw-in-place table.
//
//   [+] Building 12.3s (5/5) FINISHED
//    => [1/5] FROM ubuntu:22.04                       CACHED   0.0s
//    => [2/5] RUN apt-get update                              4.2s
//    => [3/5] COPY . /app                                     0.1s
//    => [4/5] RUN npm install                                 7.8s
//    => [5/5] EXPORTING image sha256:abc123...                0.2s
//
// In non-TTY mode the view degrades : each completed step prints
// once on its own line, no cursor moves, raw stderr passthrough.

public extension UX {
    final class BuildView: @unchecked Sendable {
        public struct Step: Sendable {
            public var index: Int        // 1-based
            public var total: Int
            public var instruction: String   // e.g. "FROM ubuntu:22.04"
            public var status: Status
            public var startedAt: Date
            public var finishedAt: Date?

            public enum Status: Sendable { case running, cached, done, failed }
        }

        private let sticky = StickyView()
        private let lock = NSLock()
        private var steps: [Int: Step] = [:]
        private var order: [Int] = []
        private var startedAt = Date()
        private var finalHash: String?
        private var finalTag: String?
        private let animated: Bool
        // Buffer of raw stderr lines surfaced when a step fails so the user
        // sees the actual command output instead of a bare "exit 1".
        private var pendingErrors: [String] = []

        public init() {
            self.animated = UX.TTY.current.animationEnabled
        }

        // Feed one event off the daemon's streaming pipe. `kind` is the
        // stream the event arrived on (.status / .stdout / .stderr / .error).
        public func ingest(stream: StreamEvent.Stream, line: String) {
            let parsed = BuildEvent.parse(stream: stream, line: line)
            lock.lock()
            switch parsed {
            case .step(let n, let total, let kw, let args):
                // A new step starts ; mark the previous one as done if it
                // was still running.
                if let last = order.last, var prev = steps[last], prev.status == .running {
                    prev.status = .done
                    prev.finishedAt = Date()
                    steps[last] = prev
                }
                let instruction = args.isEmpty ? kw : "\(kw) \(args)"
                if steps[n] == nil { order.append(n) }
                steps[n] = Step(index: n, total: total, instruction: instruction,
                                status: .running, startedAt: Date(), finishedAt: nil)
            case .cacheHit:
                // Cache hit refers to the most recent step.
                if let last = order.last, var step = steps[last] {
                    step.status = .cached
                    step.finishedAt = Date()
                    steps[last] = step
                }
            case .stderr(let text):
                pendingErrors.append(text)
            case .error(let text):
                if let last = order.last, var step = steps[last] {
                    step.status = .failed
                    step.finishedAt = Date()
                    steps[last] = step
                }
                pendingErrors.append(text)
            case .builtHash(let h):  finalHash = h
            case .taggedAs(let t):   finalTag = t
            case .ignore:            break
            }
            let frame = renderLocked()
            lock.unlock()
            sticky.render(frame)
        }

        // Call once the streaming closure returns. Flips the last running
        // step to .done, draws the final summary, and prints any buffered
        // stderr below the table.
        public func finalize() {
            lock.lock()
            if let last = order.last, var step = steps[last], step.status == .running {
                step.status = .done
                step.finishedAt = Date()
                steps[last] = step
            }
            let frame = renderLocked(finished: true)
            let errs = pendingErrors
            pendingErrors.removeAll()
            lock.unlock()
            sticky.finalize(frame)
            for e in errs where !e.isEmpty {
                FileHandle.standardError.write(Data(e.utf8))
            }
        }

        // MARK: - rendering

        private func renderLocked(finished: Bool = false) -> [String] {
            // Header : "[+] Building 12.3s (3/5)" or "FINISHED" once done.
            let totalElapsed = Date().timeIntervalSince(startedAt)
            let total = order.compactMap { steps[$0]?.total }.max() ?? 0
            let doneCount = order.compactMap { steps[$0] }.filter { $0.status != .running }.count
            let suffix = finished
                ? "FINISHED"
                : "(\(doneCount)/\(total))"
            let header = " " + UX.TTY.paint("[+] Building", .progress) + " \(UX.formatElapsed(totalElapsed)) " + UX.TTY.paint(suffix, .dim)

            // Each step : " => [n/N] <instruction>     <status>  <elapsed>"
            let widest = order.compactMap { steps[$0]?.instruction.count }.max() ?? 40
            var lines: [String] = [header]
            for n in order {
                guard let step = steps[n] else { continue }
                let arrow = step.status == .failed
                    ? UX.TTY.paint("✗", .failure)
                    : (step.status == .running
                        ? UX.TTY.paint(UX.spinnerFrames[doneCount % UX.spinnerFrames.count], .progress)
                        : UX.TTY.paint("=>", .progress))
                let stepIdx = UX.TTY.paint("[\(step.index)/\(step.total)]", .dim)
                let inst = step.instruction.padding(toLength: max(widest, step.instruction.count), withPad: " ", startingAt: 0)
                let statusCol: String = {
                    switch step.status {
                    case .cached:  return UX.TTY.paint("CACHED", .success)
                    case .done:    return UX.TTY.paint("DONE  ", .success)
                    case .failed:  return UX.TTY.paint("FAILED", .failure)
                    case .running: return UX.TTY.paint("...   ", .progress)
                    }
                }()
                let elapsed: String = {
                    if let end = step.finishedAt {
                        return UX.formatElapsed(end.timeIntervalSince(step.startedAt))
                    }
                    return UX.formatElapsed(Date().timeIntervalSince(step.startedAt))
                }()
                lines.append(" \(arrow) \(stepIdx) \(inst)  \(statusCol)  " + UX.TTY.paint(elapsed, .dim))
            }

            if finished, let hash = finalHash {
                let tag = finalTag.map { " " + UX.TTY.paint($0, .accent) } ?? ""
                let summary = " " + UX.TTY.paint(UX.Icon.success.rawValue, .success)
                    + " " + UX.TTY.paint("Built", .success) + tag
                    + " " + UX.TTY.paint("(\(hash))", .dim)
                    + " in " + UX.formatElapsed(totalElapsed)
                lines.append(summary)
            }
            return lines
        }
    }

    // Parsed shape of every line the daemon emits during a build. Keeping
    // the wire-format → enum in one place makes the parser the single
    // thing tests need to pin.
    enum BuildEvent: Sendable, Equatable {
        case step(n: Int, total: Int, keyword: String, args: String)
        case cacheHit
        case builtHash(String)
        case taggedAs(String)
        case stderr(String)
        case error(String)
        case ignore

        public static func parse(stream: StreamEvent.Stream, line: String) -> BuildEvent {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            switch stream {
            case .status:
                // "Step N/M : KEYWORD args"  (note : the daemon uses
                // " : " between number and instruction, with a colon-space
                // in the "Parsing Dockerfile" prelude. We accept both.)
                if let step = parseStep(trimmed) { return step }
                if trimmed.hasPrefix("Successfully built ") {
                    let h = String(trimmed.dropFirst("Successfully built ".count))
                    return .builtHash(h)
                }
                if trimmed.hasPrefix("Successfully tagged ") {
                    let t = String(trimmed.dropFirst("Successfully tagged ".count))
                    return .taggedAs(t)
                }
                return .ignore
            case .stdout:
                if trimmed.hasPrefix("---> Using cache") || trimmed.contains(" ---> Using cache") {
                    return .cacheHit
                }
                return .ignore
            case .stderr:
                return .stderr(line)
            case .error:
                return .error(line)
            }
        }

        private static func parseStep(_ s: String) -> BuildEvent? {
            // Accepts both "Step 0/5: Parsing Dockerfile" and
            // "Step 3/5 : RUN apt-get update".
            guard s.hasPrefix("Step ") else { return nil }
            let body = s.dropFirst("Step ".count)
            // Split into "N/M" and "instruction" on the first ":".
            guard let colonIdx = body.firstIndex(of: ":") else { return nil }
            let numberPart = body[..<colonIdx].trimmingCharacters(in: .whitespaces)
            let instructionPart = body[body.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            let slashed = numberPart.split(separator: "/")
            guard slashed.count == 2, let n = Int(slashed[0]), let total = Int(slashed[1]) else { return nil }
            // Split instruction into keyword + args.
            let words = instructionPart.split(separator: " ", maxSplits: 1).map(String.init)
            let keyword = words.first ?? instructionPart
            let args = words.count > 1 ? words[1] : ""
            return .step(n: n, total: total, keyword: keyword, args: args)
        }
    }
}
