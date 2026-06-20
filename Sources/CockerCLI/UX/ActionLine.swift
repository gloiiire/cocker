import Foundation

// Cocker UX charter §4 — the universal action-line shape used everywhere
// an action is announced (status, success, failure, in-progress).
//
// Layout :
//   " <icon> <Type>      <name>           <status>          <trailing>"
//      1ch     padded 9     padded N         padded M           free
//
// Single space after icon, two spaces between fields. When rendered inside
// a sticky multi-line table, pass explicit nameWidth/statusWidth so every
// row aligns to the longest cell in the group.

public extension UX {
    struct ActionLine: Sendable {
        public var icon: Icon
        public var type: ObjectType?     // optional — some lines aren't object-scoped
        public var name: String
        public var status: String        // "Started", "Pulling", "Remove failed"...
        public var trailing: String?     // "1.8s", "12 MB / 18 MB", nil
        public var statusColor: Color?   // override (default = icon.color)

        public init(
            icon: Icon,
            type: ObjectType? = nil,
            name: String,
            status: String,
            trailing: String? = nil,
            statusColor: Color? = nil
        ) {
            self.icon = icon
            self.type = type
            self.name = name
            self.status = status
            self.trailing = trailing
            self.statusColor = statusColor
        }

        public func render(nameWidth: Int? = nil, statusWidth: Int? = nil) -> String {
            let iconStr = UX.TTY.paint(icon.rawValue, icon.color)
            let typeStr: String = type.map { UX.TTY.paint($0.padded, .dim) } ?? String(repeating: " ", count: ObjectType.labelWidth)
            let paddedName = name.padding(toLength: max(name.count, nameWidth ?? name.count), withPad: " ", startingAt: 0)
            let statusRaw = status.padding(toLength: max(status.count, statusWidth ?? status.count), withPad: " ", startingAt: 0)
            let statusStr = UX.TTY.paint(statusRaw, statusColor ?? icon.color)
            var out = " \(iconStr) \(typeStr)  \(paddedName)  \(statusStr)"
            if let t = trailing, !t.isEmpty {
                out += "  " + UX.TTY.paint(t, .dim)
            }
            return out
        }

        // Width helpers for sticky-view alignment.
        public var nameLength: Int { name.count }
        public var statusLength: Int { status.count }
    }

    // Convenience helpers. These wrap ActionLine for the most common cases.

    static func actionStarted(_ type: ObjectType, _ name: String, elapsed: TimeInterval? = nil) -> ActionLine {
        ActionLine(icon: .success, type: type, name: name, status: "Started", trailing: elapsed.map(formatElapsed))
    }

    static func actionCreated(_ type: ObjectType, _ name: String, elapsed: TimeInterval? = nil) -> ActionLine {
        ActionLine(icon: .success, type: type, name: name, status: "Created", trailing: elapsed.map(formatElapsed))
    }

    static func actionRemoved(_ type: ObjectType, _ name: String, elapsed: TimeInterval? = nil) -> ActionLine {
        ActionLine(icon: .success, type: type, name: name, status: "Removed", trailing: elapsed.map(formatElapsed))
    }

    static func actionRunning(_ type: ObjectType, _ name: String, verb: Verb, elapsed: TimeInterval? = nil) -> ActionLine {
        ActionLine(icon: .progress, type: type, name: name, status: verb.present, trailing: elapsed.map(formatElapsed))
    }

    static func actionDone(_ type: ObjectType, _ name: String, verb: Verb, elapsed: TimeInterval? = nil) -> ActionLine {
        ActionLine(icon: .success, type: type, name: name, status: verb.past, trailing: elapsed.map(formatElapsed))
    }

    static func actionFailed(_ type: ObjectType, _ name: String, status: String) -> ActionLine {
        ActionLine(icon: .failure, type: type, name: name, status: status)
    }

    // Print an "action complete" result. Pretty action line in a TTY, bare
    // name on stdout when piped — preserves Docker-style script composability
    // (`cocker stop x | xargs ...`) while giving humans the polished view.
    static func printResult(
        _ type: ObjectType,
        _ name: String,
        verb: Verb,
        elapsed: TimeInterval? = nil
    ) {
        if UX.TTY.current.isInteractive {
            print(actionDone(type, name, verb: verb, elapsed: elapsed).render())
        } else {
            print(name)
        }
    }

    // Same shape for a CREATED resource (returns id/name on creation, like
    // `docker network create`). The non-TTY branch prints the bare id.
    static func printCreated(
        _ type: ObjectType,
        _ name: String,
        elapsed: TimeInterval? = nil
    ) {
        if UX.TTY.current.isInteractive {
            print(actionCreated(type, name, elapsed: elapsed).render())
        } else {
            print(name)
        }
    }

    // "1.8s", "120ms", "1m 12s" — charter convention.
    static func formatElapsed(_ d: TimeInterval) -> String {
        if d < 1.0 { return String(format: "%dms", Int(d * 1000)) }
        if d < 60.0 { return String(format: "%.1fs", d) }
        let m = Int(d) / 60
        let s = Int(d) % 60
        return "\(m)m \(s)s"
    }
}
