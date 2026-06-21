import CockerCore
import Foundation

// Cocker UX charter §8.3 + §13.1 — docker-compose-style sticky view for
// `cocker compose up`. Consumes the daemon's compose event stream and
// renders a per-resource action table that redraws in place :
//
//   [+] Running 3/3
//    ✓ Network    myapp_default       Created     0.1s
//    ✓ Container  myapp_db_1          Started     1.8s
//    ⠋ Container  myapp_web_1         Building    3.2s
//
// In non-TTY mode the view falls back to one-line-per-event chronological
// print, with stderr passthrough preserved.

public extension UX {
    final class ComposeUpView: @unchecked Sendable {
        public struct Resource: Sendable {
            public var type: ObjectType   // .container, .network, .volume, .image, .service
            public var name: String       // e.g. "myapp_db_1"
            public var status: Status
            public var startedAt: Date
            public var finishedAt: Date?

            public enum Status: Sendable, Equatable {
                case running(String)   // e.g. "Building", "Starting", "Pulling"
                case done(String)      // e.g. "Started", "Created", "Built", "Pulled"
                case failed(String)
            }
        }

        private let sticky = StickyView()
        private let lock = NSLock()
        private var resources: [String: Resource] = [:]   // key = "type:name"
        private var order: [String] = []
        private var startedAt = Date()
        private var pendingErrors: [String] = []
        private let animated: Bool

        public init() {
            self.animated = UX.TTY.current.animationEnabled
        }

        public func ingest(stream: StreamEvent.Stream, line: String) {
            let parsed = ComposeEvent.parse(stream: stream, line: line)
            lock.lock()
            switch parsed {
            case .creating(let type, let name):
                upsert(type: type, name: name, status: .running("Creating"))
            case .created(let type, let name):
                upsert(type: type, name: name, status: .done("Created"))
            case .building(let service):
                upsert(type: .service, name: service, status: .running("Building"))
            case .built(let service):
                upsert(type: .service, name: service, status: .done("Built"))
            case .pulling(let image):
                upsert(type: .image, name: image, status: .running("Pulling"))
            case .pulled(let image):
                upsert(type: .image, name: image, status: .done("Pulled"))
            case .alreadyExists(let image):
                upsert(type: .image, name: image, status: .done("Already exists"))
            case .starting(let container):
                upsert(type: .container, name: container, status: .running("Starting"))
            case .started(let container):
                upsert(type: .container, name: container, status: .done("Started"))
            case .stderr(let text):
                pendingErrors.append(text)
            case .error(let text):
                pendingErrors.append(text)
                if let last = order.last, var r = resources[last] {
                    r.status = .failed("Failed")
                    r.finishedAt = Date()
                    resources[last] = r
                }
            case .ignore:
                break
            }
            let frame = renderLocked()
            lock.unlock()
            sticky.render(frame)
        }

        public func finalize() {
            lock.lock()
            let frame = renderLocked(finished: true)
            let errs = pendingErrors
            pendingErrors.removeAll()
            lock.unlock()
            sticky.finalize(frame)
            for e in errs where !e.isEmpty {
                FileHandle.standardError.write(Data(e.utf8))
            }
        }

        // MARK: - state mutation (called with lock held)

        private func upsert(type: ObjectType, name: String, status: Resource.Status) {
            let key = "\(type.label):\(name)"
            if var r = resources[key] {
                r.status = status
                if case .done = status { r.finishedAt = Date() }
                if case .failed = status { r.finishedAt = Date() }
                resources[key] = r
            } else {
                order.append(key)
                resources[key] = Resource(
                    type: type, name: name, status: status,
                    startedAt: Date(), finishedAt: nil
                )
            }
        }

        // MARK: - rendering

        private func renderLocked(finished: Bool = false) -> [String] {
            let doneCount = order.compactMap { resources[$0] }.filter {
                if case .running = $0.status { return false }
                return true
            }.count
            let totalCount = order.count
            let headerSuffix = finished
                ? UX.TTY.paint("done", .dim)
                : UX.TTY.paint("\(doneCount)/\(totalCount)", .dim)
            let header = " " + UX.TTY.paint("[+] Running", .progress) + " " + headerSuffix

            // Compute widths for alignment.
            let nameWidth = order.compactMap { resources[$0]?.name.count }.max() ?? 0
            let statusWidth = order.compactMap { resources[$0]?.statusText.count }.max() ?? 0

            var lines: [String] = [header]
            for key in order {
                guard let r = resources[key] else { continue }
                let icon: UX.Icon = {
                    switch r.status {
                    case .running: return .progress
                    case .done:    return .success
                    case .failed:  return .failure
                    }
                }()
                let elapsedStr: String = {
                    if let end = r.finishedAt {
                        return UX.formatElapsed(end.timeIntervalSince(r.startedAt))
                    }
                    if case .running = r.status {
                        return UX.formatElapsed(Date().timeIntervalSince(r.startedAt))
                    }
                    return ""
                }()
                let actionLine = UX.ActionLine(
                    icon: icon, type: r.type, name: r.name,
                    status: r.statusText, trailing: elapsedStr.isEmpty ? nil : elapsedStr
                )
                lines.append(actionLine.render(nameWidth: nameWidth, statusWidth: statusWidth))
            }

            if finished && !order.isEmpty {
                let total = UX.formatElapsed(Date().timeIntervalSince(startedAt))
                let containers = resources.values.filter { $0.type == .container }
                let summary = " " + UX.TTY.paint(UX.Icon.success.rawValue, .success)
                    + " " + UX.TTY.paint("\(containers.count) container\(containers.count == 1 ? "" : "s") started", .success)
                    + " in " + total
                lines.append(summary)
            }
            return lines
        }
    }

    // Wire-format parser : every line the compose engine emits routed to a
    // structured event. Tested independently of the StickyView wiring.
    enum ComposeEvent: Sendable, Equatable {
        case creating(type: ObjectType, name: String)
        case created(type: ObjectType, name: String)
        case building(service: String)
        case built(service: String)
        case pulling(image: String)
        case pulled(image: String)
        case alreadyExists(image: String)
        case starting(container: String)
        case started(container: String)
        case stderr(String)
        case error(String)
        case ignore

        public static func parse(stream: StreamEvent.Stream, line: String) -> ComposeEvent {
            switch stream {
            case .status:
                return parseStatus(line.trimmingCharacters(in: .whitespacesAndNewlines))
            case .stderr:
                return .stderr(line)
            case .error:
                return .error(line)
            case .stdout:
                return .ignore
            }
        }

        private static func parseStatus(_ s: String) -> ComposeEvent {
            // "Created network: <name>" / "Created volume: <name>"
            if let name = strip(s, prefix: "Created network: ") { return .created(type: .network, name: name) }
            if let name = strip(s, prefix: "Created volume: ")  { return .created(type: .volume,  name: name) }

            // "Building <service>..."  / "Built <tag>"
            if let svc = strip(s, prefix: "Building ", suffix: "...") { return .building(service: svc) }
            if let svc = strip(s, prefix: "Built ") { return .built(service: svc) }

            // "Pulling <image>..." / "Pulled <image>" / "<image>: Already exists"
            if let img = strip(s, prefix: "Pulling ", suffix: "...") { return .pulling(image: img) }
            if let img = strip(s, prefix: "Pulled ") { return .pulled(image: img) }
            if s.hasSuffix(": Already exists") {
                let img = String(s.dropLast(": Already exists".count))
                return .alreadyExists(image: img)
            }

            // "Starting <container>..." / "Started container <id12>"
            if let c = strip(s, prefix: "Starting ", suffix: "...") { return .starting(container: c) }
            if let c = strip(s, prefix: "Started container ") { return .started(container: c) }

            // Headers we ignore ("Starting project: …", "All services started.")
            return .ignore
        }

        private static func strip(_ s: String, prefix: String, suffix: String? = nil) -> String? {
            guard s.hasPrefix(prefix) else { return nil }
            var body = String(s.dropFirst(prefix.count))
            if let suffix {
                guard body.hasSuffix(suffix) else { return nil }
                body = String(body.dropLast(suffix.count))
            }
            return body
        }
    }

    fileprivate static func _placeholder() {}
}

private extension UX.ComposeUpView.Resource {
    var statusText: String {
        switch status {
        case .running(let s): return s
        case .done(let s):    return s
        case .failed(let s):  return s
        }
    }
}
