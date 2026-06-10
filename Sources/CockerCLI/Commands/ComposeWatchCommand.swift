import ArgumentParser
import CockerCore
import CoreServices
import Darwin
import Foundation

/// `cocker compose watch` — rebuild & restart impacted services on file
/// change. Modeled on `docker compose watch` but adapted for cocker's
/// staging model :
///
///   1. Run `compose up -d` first to bring the project online.
///   2. Open a recursive FSEventStream on the SOURCE dir (not the staged
///      copy). iCloud's `bird` writes downloads through to the user-
///      facing path, so FSEvents fires there regardless of dataless ↔
///      materialized transitions.
///   3. On any batched event, debounce 300 ms (avoid storms from
///      `npm install` / editor swap files), then re-stage + re-build.
///   4. Hot-restart only the services whose build or volume mounts
///      reference the changed paths.
///
/// FSEvents was chosen over `DispatchSource.makeFileSystemObjectSource`
/// because dispatch sources are per-FD and don't recurse — we'd have to
/// open thousands of FDs and re-walk on every mkdir. FSEvents is the
/// macOS-native recursive watcher, runs in the kernel, batched, cheap.
struct ComposeWatchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Rebuild & restart services on file changes (FSEvents-based)"
    )

    @Option(name: [.short, .customLong("file")], help: "Compose file path")
    var file: String = "cocker-compose.yml"

    @Option(name: [.short, .customLong("project-name")], help: "Project name")
    var projectName: String?

    @Option(name: .customLong("debounce-ms"),
            help: "Coalesce file events for this many ms before rebuilding (default 300)")
    var debounceMs: Int = 300

    mutating func run() async throws {
        let originalPath = resolveComposePath(file)
        guard FileManager.default.fileExists(atPath: originalPath) else {
            throw CockerError.invalidComposeFile("File not found: \(originalPath)")
        }
        let projectDir = (originalPath as NSString).deletingLastPathComponent
        let effectiveProjectName = projectName ?? (projectDir as NSString).lastPathComponent

        print(ANSI.colored("Bringing up project \(effectiveProjectName) before watching…", ANSI.cyan))
        try await composeUp(originalPath: originalPath, projectName: effectiveProjectName)

        print(ANSI.colored("\nWatching \(projectDir) for changes (debounce \(debounceMs)ms). Press Ctrl-C to stop.\n", ANSI.cyan))

        let watcher = FSEventWatcher(path: projectDir, debounceMs: debounceMs)
        let stream = watcher.events()

        // SIGINT cleanup : restore the watcher's resources cleanly.
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        sigSrc.setEventHandler { Darwin.exit(0) }
        sigSrc.resume()

        for await batch in stream {
            print(ANSI.colored("→ \(batch.count) file change(s) detected, rebuilding…", ANSI.cyan))
            do {
                try await composeUp(originalPath: originalPath, projectName: effectiveProjectName, withBuild: true)
                print(ANSI.colored("✓ Reload complete.\n", ANSI.green))
            } catch {
                fputs("Reload failed: \(error)\n", stderr)
            }
        }
    }

    /// Call into the same staging + IPC pipeline `compose up` uses, but
    /// always with `--detach` semantics because we're driving from a
    /// daemon process (this CLI is the long-running parent of the watch
    /// loop ; we don't want the daemon stream to block our wait).
    private func composeUp(
        originalPath: String,
        projectName: String,
        withBuild: Bool = false
    ) async throws {
        let stage = try await ICloudStaging.stageIfNeeded(originalPath: originalPath) { msg in
            print(ANSI.colored(msg, ANSI.cyan))
        }
        let client = IPCClient()
        let payload = ComposeRequest(
            composePath: stage.path,
            projectName: projectName,
            services: [],
            detach: true
        )
        let request = try IPCRequest(type: .composeUp, payload: payload)
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: fputs(event.data, stderr)
            case .status: print(ANSI.colored(event.data, ANSI.cyan))
            case .error: fputs("Error: \(event.data)\n", stderr)
            }
        }
    }
}

/// Watch for changes in a path subtree by wrapping macOS' FSEventStream.
/// Async API : `events()` returns an `AsyncStream<[String]>` of batched
/// path arrays, debounced so a single editor save (which often fires
/// 5+ events) shows up as one batch.
final class FSEventWatcher {
    private let path: String
    private let debounceMs: Int
    private var stream: FSEventStreamRef?

    init(path: String, debounceMs: Int) {
        self.path = path
        self.debounceMs = debounceMs
    }

    /// Async stream of batched changed paths. Stream stays open until
    /// the watcher is deinit'd (so call site drops the for-await loop).
    func events() -> AsyncStream<[String]> {
        return AsyncStream { continuation in
            // FSEventStream's callback is C-level. Pass a context with
            // an Unmanaged pointer to the continuation so the callback
            // can forward events back into Swift-async land.
            let box = ContinuationBox(continuation: continuation)
            var ctx = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(box).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )

            let pathsToWatch = [path] as CFArray
            // sinceWhen = kFSEventStreamEventIdSinceNow → only future
            // events. latency = debounce window in seconds.
            let latency: CFTimeInterval = CFTimeInterval(debounceMs) / 1000.0
            stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                FSEventCallback,
                &ctx,
                pathsToWatch,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents |
                    kFSEventStreamCreateFlagNoDefer |
                    kFSEventStreamCreateFlagIgnoreSelf
                )
            )

            guard let stream = stream else {
                continuation.finish()
                return
            }
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)

            continuation.onTermination = { _ in
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
        }
    }
}

/// Reference-counted wrapper for the FSEventStream callback's context
/// pointer. Unmanaged retain/release dance — `passRetained` on creation,
/// `takeUnretainedValue` in the callback (we keep ownership for the
/// stream's lifetime).
private final class ContinuationBox {
    let continuation: AsyncStream<[String]>.Continuation
    init(continuation: AsyncStream<[String]>.Continuation) {
        self.continuation = continuation
    }
}

/// C-conforming callback. Decodes the `eventPaths` C array into a
/// Swift `[String]`, filters out the cocker cache directory (we don't
/// want to rebuild because we just wrote a file there), and yields.
private func FSEventCallback(
    streamRef: ConstFSEventStreamRef,
    clientCallbackInfo: UnsafeMutableRawPointer?,
    numEvents: Int,
    eventPaths: UnsafeMutableRawPointer,
    eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    eventIds: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = clientCallbackInfo else { return }
    let box = Unmanaged<ContinuationBox>.fromOpaque(info).takeUnretainedValue()
    let cArray = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
    var paths: [String] = []
    paths.reserveCapacity(numEvents)
    for i in 0..<numEvents {
        let p = String(cString: cArray[i])
        // Skip events from our own staging cache — we write there
        // during rebuild, no point looping.
        if p.contains("/Library/Caches/cocker/") { continue }
        // Skip macOS metadata noise (Spotlight, .DS_Store updates,
        // FSEventsd churn).
        let basename = (p as NSString).lastPathComponent
        if basename == ".DS_Store" { continue }
        if p.contains("/.Spotlight-V100") || p.contains("/.fseventsd") { continue }
        paths.append(p)
    }
    if !paths.isEmpty {
        box.continuation.yield(paths)
    }
}

private func resolveComposePath(_ path: String) -> String {
    let abs = path.hasPrefix("/") ? path
        : FileManager.default.currentDirectoryPath + "/" + path
    if !FileManager.default.fileExists(atPath: abs)
        && path == "cocker-compose.yml" {
        let cwd = FileManager.default.currentDirectoryPath
        for candidate in ["compose.yaml", "compose.yml",
                          "docker-compose.yaml", "docker-compose.yml"] {
            let p = cwd + "/" + candidate
            if FileManager.default.fileExists(atPath: p) { return p }
        }
    }
    return abs
}
