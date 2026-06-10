import ArgumentParser
import CockerCore
import Foundation

/// Top-level `cocker icloud` umbrella. Holds dev/diagnostic subcommands
/// that surface what cocker sees about Apple's iCloud Drive daemon
/// (`bird`) — useful for debugging "why is my build slow on this
/// project" without having to dig into `brctl` and Console.app.
struct ICloudCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "icloud",
        abstract: "Inspect & control iCloud-aware behavior (cache, materialization, watch)",
        subcommands: [
            ICloudStatusCommand.self,
            ICloudPrefetchCommand.self,
            ICloudCacheClearCommand.self,
        ]
    )
}

/// `cocker icloud status <path>` — print which files under `path` are
/// materialized, dataless, or downloading. Useful before a `compose up`
/// to predict whether the staging will be fast or slow.
struct ICloudStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show iCloud materialization state for a directory"
    )

    @Argument(help: "Directory to inspect (default: current dir)")
    var path: String = "."

    @Flag(name: .customLong("json"), help: "Emit machine-readable JSON")
    var json = false

    mutating func run() async throws {
        let fm = FileManager.default
        let abs = path.hasPrefix("/")
            ? path
            : fm.currentDirectoryPath + "/" + path
        let resolved = URL(fileURLWithPath: abs).standardized.path

        if !ICloudStaging.isICloudPath(resolved) {
            if json {
                print(#"{"iCloud":false,"path":"\#(resolved)"}"#)
            } else {
                print("\(resolved) is NOT under iCloud Drive — bird won't touch it.")
            }
            return
        }

        print("Scanning \(resolved) (URLResourceValues per file)…")
        let state = await ICloudInspector.inspect(dir: resolved)

        if json {
            let payload: [String: Any] = [
                "iCloud": true,
                "path": resolved,
                "totalFiles": state.totalFiles,
                "downloaded": state.downloaded,
                "current": state.current,
                "notDownloaded": state.notDownloaded,
                "downloading": state.downloading,
                "totalBytes": state.totalBytes,
                "pendingBytes": state.pendingBytes,
                "averageDownloadProgress": state.averageDownloadProgress as Any,
                "needsPreFetch": state.needsPreFetch,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                print(s)
            }
            return
        }

        if state.totalFiles == 0 {
            print("⚠️  bird returned no results — daemon may be offline or path empty.")
            print("    Try `brctl log --shorten` to inspect bird's recent activity.")
            return
        }

        let bf = ByteCountFormatter()
        bf.countStyle = .file
        print("")
        print("  Files:       \(state.totalFiles)")
        print("  Total size:  \(bf.string(fromByteCount: state.totalBytes))")
        print("  ─────────────────────────────")
        print("  Downloaded:    \(state.downloaded) (\(percent(state.downloaded, of: state.totalFiles)))")
        print("    of which current:  \(state.current)")
        print("  Dataless:      \(state.notDownloaded) (\(percent(state.notDownloaded, of: state.totalFiles)))")
        print("  Downloading:   \(state.downloading) (\(percent(state.downloading, of: state.totalFiles)))")
        print("  Pending bytes: \(bf.string(fromByteCount: state.pendingBytes))")
        if let p = state.averageDownloadProgress {
            print("  In-flight progress: \(Int(p * 100))%")
        }
        print("")
        if state.needsPreFetch {
            print("→ A `cocker icloud prefetch \(resolved)` (or `cocker compose up`) will materialize the missing files first.")
        } else {
            print("✓ Fully local — staging will be instantaneous.")
        }
    }

    private func percent(_ n: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        let p = Double(n) / Double(total) * 100
        return String(format: "%.0f%%", p)
    }
}

/// `cocker icloud prefetch <path>` — fire `brctl download` and stream
/// its progress. Same thing the staging code does silently, but exposed
/// so users can warm the cache ahead of `compose up`.
struct ICloudPrefetchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prefetch",
        abstract: "Eagerly download all dataless iCloud files in a directory"
    )

    @Argument(help: "Directory to materialize")
    var path: String = "."

    mutating func run() async throws {
        let abs = path.hasPrefix("/")
            ? path
            : FileManager.default.currentDirectoryPath + "/" + path
        let resolved = URL(fileURLWithPath: abs).standardized.path

        guard ICloudStaging.isICloudPath(resolved) else {
            fputs("Not an iCloud path: \(resolved)\n", stderr)
            throw ExitCode.failure
        }

        let before = await ICloudInspector.inspect(dir: resolved)
        if !before.needsPreFetch {
            print("Already fully local (\(before.totalFiles) files). Nothing to do.")
            return
        }
        print("Pre-fetching \(before.notDownloaded) dataless file(s) via brctl…")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/brctl")
        proc.arguments = ["download", resolved]
        try proc.run()
        proc.waitUntilExit()

        let after = await ICloudInspector.inspect(dir: resolved)
        let materialized = before.notDownloaded - after.notDownloaded
        print("✓ Materialized \(materialized) file(s). \(after.notDownloaded) still dataless.")
    }
}

/// `cocker icloud cache clear` — wipe `~/Library/Caches/cocker/staging/`.
struct ICloudCacheClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache-clear",
        abstract: "Wipe the local iCloud staging cache"
    )

    mutating func run() async throws {
        let freed = ICloudStaging.clearCache()
        let bf = ByteCountFormatter()
        bf.countStyle = .file
        print("Cleared staging cache. Freed \(bf.string(fromByteCount: Int64(freed))).")
    }
}
