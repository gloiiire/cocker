import Foundation

// Cocker UX charter §3 — single source of truth for icons, colors, verbs
// and object types. Every command renders through these tokens, never with
// inline ANSI codes or hand-rolled strings. See docs/UX-CHARTER.md.

public enum UX {}

public extension UX {
    enum Icon: String, CaseIterable, Sendable {
        case success  = "✓"
        case failure  = "✗"
        case progress = "⠋"
        case action   = "→"
        case item     = "•"
        case warn     = "⚠"
        case restart  = "↻"
        case prompt   = "?"

        public var color: Color {
            switch self {
            case .success: return .success
            case .failure: return .failure
            case .progress: return .progress
            case .action: return .progress
            case .item: return .dim
            case .warn: return .warn
            case .restart: return .restart
            case .prompt: return .accent
            }
        }
    }

    enum Color: Sendable {
        case success    // green
        case failure    // red
        case progress   // cyan
        case warn       // yellow
        case restart    // yellow (semantic alias)
        case accent     // magenta — IDs, hashes
        case dim        // gray — secondary
        case `default`  // no color

        public var ansi: String {
            switch self {
            case .success:  return "\u{001B}[32m"
            case .failure:  return "\u{001B}[31m"
            case .progress: return "\u{001B}[36m"
            case .warn:     return "\u{001B}[33m"
            case .restart:  return "\u{001B}[33m"
            case .accent:   return "\u{001B}[35m"
            case .dim:      return "\u{001B}[2m"
            case .default:  return ""
            }
        }
    }

    enum Modifier: Sendable {
        case bold, dim, italic, underline

        public var ansi: String {
            switch self {
            case .bold:      return "\u{001B}[1m"
            case .dim:       return "\u{001B}[2m"
            case .italic:    return "\u{001B}[3m"
            case .underline: return "\u{001B}[4m"
            }
        }
    }

    // Verb conjugation table. Present continuous while running, simple
    // past when done. Never "Successfully X" — Docker does this, it's noise.
    enum Verb: Sendable, CaseIterable {
        case start, stop, build, pull, push, remove, create, connect,
             disconnect, restart, pause, unpause, commit, export, importTar,
             rebuild, tag, save, load, inspect

        public var present: String {
            switch self {
            case .start:      return "Starting"
            case .stop:       return "Stopping"
            case .build:      return "Building"
            case .pull:       return "Pulling"
            case .push:       return "Pushing"
            case .remove:     return "Removing"
            case .create:     return "Creating"
            case .connect:    return "Connecting"
            case .disconnect: return "Disconnecting"
            case .restart:    return "Restarting"
            case .pause:      return "Pausing"
            case .unpause:    return "Unpausing"
            case .commit:     return "Committing"
            case .export:     return "Exporting"
            case .importTar:  return "Importing"
            case .rebuild:    return "Rebuilding"
            case .tag:        return "Tagging"
            case .save:       return "Saving"
            case .load:       return "Loading"
            case .inspect:    return "Inspecting"
            }
        }

        public var past: String {
            switch self {
            case .start:      return "Started"
            case .stop:       return "Stopped"
            case .build:      return "Built"
            case .pull:       return "Pulled"
            case .push:       return "Pushed"
            case .remove:     return "Removed"
            case .create:     return "Created"
            case .connect:    return "Connected"
            case .disconnect: return "Disconnected"
            case .restart:    return "Restarted"
            case .pause:      return "Paused"
            case .unpause:    return "Unpaused"
            case .commit:     return "Committed"
            case .export:     return "Exported"
            case .importTar:  return "Imported"
            case .rebuild:    return "Rebuilt"
            case .tag:        return "Tagged"
            case .save:       return "Saved"
            case .load:       return "Loaded"
            case .inspect:    return "Inspected"
            }
        }
    }

    enum ObjectType: Sendable, CaseIterable {
        case container, image, network, volume, service, secret,
             config, plugin, daemon, context

        public var label: String {
            switch self {
            case .container: return "Container"
            case .image:     return "Image"
            case .network:   return "Network"
            case .volume:    return "Volume"
            case .service:   return "Service"
            case .secret:    return "Secret"
            case .config:    return "Config"
            case .plugin:    return "Plugin"
            case .daemon:    return "Daemon"
            case .context:   return "Context"
            }
        }

        // Width of the longest type label, so action lines can left-pad
        // for column alignment across mixed-type tables (see §4).
        public static let labelWidth = 9 // "Container"

        public var padded: String {
            label.padding(toLength: Self.labelWidth, withPad: " ", startingAt: 0)
        }
    }
}
