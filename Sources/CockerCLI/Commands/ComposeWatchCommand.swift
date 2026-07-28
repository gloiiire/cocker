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

    @Flag(name: [.short, .customLong("detach")],
          help: "Run the watch loop in the background. Returns the PID and exits.")
    var detach: Bool = false

    @Flag(name: .customLong("stop"),
          help: "Stop a previously detached watch loop for this project.")
    var stop: Bool = false

    @Flag(name: .customLong("status"),
          help: "Show whether a detached watch is running for this project.")
    var status: Bool = false

    @Flag(name: .customLong("logs"),
          help: "Tail the detached watch's log file (like `tail -f`).")
    var logs: Bool = false

    @Flag(name: [.short, .customLong("attach")],
          help: "Re-attach : stop the detached watch and resume in the foreground (interactive footer + d/q keys). Containers keep running.")
    var attach: Bool = false

    mutating func run() async throws {
        let originalPath = resolveComposePath(file)
        guard FileManager.default.fileExists(atPath: originalPath) else {
            throw CockerError.invalidComposeFile("File not found: \(originalPath)")
        }
        let projectDir = (originalPath as NSString).deletingLastPathComponent
        // Normalize here too (not just daemon-side) so the "→ Bringing up X"
        // banner we print below shows the SAME name the containers actually
        // get — otherwise a `Memoire M2` dir would display `Memoire M2` while
        // the containers are named `memoire_m2_api_1`.
        let effectiveProjectName = ProjectName.normalize(projectName ?? (projectDir as NSString).lastPathComponent)

        // Sub-commands disguised as flags. ArgumentParser doesn't make
        // it cheap to nest subcommands two levels deep ("compose watch
        // stop") so we route on flags ; the help text reads cleanly
        // because each flag is self-describing.
        if stop   { try handleStop(projectDir: projectDir); return }
        if status { handleStatus(projectDir: projectDir); return }
        if logs   { try handleLogs(projectDir: projectDir); return }

        // `--detach` : re-exec ourselves without -d, fully detached. The
        // parent prints the PID and exits. The child reparents to launchd
        // (PPID=1) and writes its output to <projectDir>/.cocker/watch.log
        // so the user can `tail -f` it later. We funnel both the "up"
        // pre-step and the loop output into the same log so a single
        // tail captures everything from boot onward.
        // `--attach` : take over a detached background watch and resume in
        // the foreground. We stop the background process (containers are
        // untouched — the watcher just watches files) then fall through to
        // the normal interactive loop below. Takes precedence over `-d`.
        if attach {
            if let stopped = Self.stopDetached(projectDir: projectDir) {
                print(" " + UX.TTY.paint("→ Re-attaching", .progress) + " " + UX.TTY.paint("(stopped background watch pid \(stopped))", .dim))
            } else {
                print(" " + UX.TTY.paint("→ Attaching", .progress) + " " + UX.TTY.paint("(no background watch was running — starting fresh)", .dim))
            }
        } else if detach {
            try Self.detachAndExit(projectDir: projectDir, originalArgs: CommandLine.arguments)
            return
        }

        // At most one watch loop per project — two watchers both running
        // `compose up --build` on the same events would race and double-build.
        // Exclusion is enforced with an advisory flock() on `.cocker/watch.lock`
        // held for the lifetime of whoever runs the loop (foreground watch OR
        // the detached child). The kernel releases the lock automatically when
        // that process dies, so — unlike a hand-rolled pidfile — there is no
        // stale lock to recover, no unlink race, and no malformed-file wedge.
        // The pidfile is now just an advisory record of who holds it, written
        // here so --status / --stop can find us.
        // Every path that runs the loop takes the lock — foreground, --attach
        // (its stopDetached above already released the previous holder's), and
        // the detached child. The detach PARENT returns via detachAndExit and
        // never reaches here.
        guard Self.acquireWatchLock(projectDir: projectDir) else {
            UX.Warning.emit(
                "a watch is already running for this project",
                note: "re-attach with `cocker compose watch --attach`, or stop it with `cocker compose watch --stop`"
            )
            return
        }
        // Only the detached background child records the pidfile : it is the
        // one whose output goes to watch.log, so --status/--logs/--stop track
        // it. A foreground / attached watcher shows output live in its own
        // terminal and stays unregistered — so `--logs` from another terminal
        // never latches onto its static log file.
        if ProcessInfo.processInfo.environment["COCKER_WATCH_DETACHED_CHILD"] == "1" {
            try? "\(getpid())\n".write(toFile: Self.pidFilePath(projectDir),
                                       atomically: true, encoding: .utf8)
        }

        let urls = ServiceURLs()

        // Charter §12 — name the macOS daemons we're talking to so the user
        // understands what's making the project "alive". FSEvents is the
        // kernel-level file-change subscription ; bird (iCloud) hand-off
        // happens inside composeUp() when the project lives in iCloud Drive.
        print(" " + UX.TTY.paint("→ Bringing up", .progress) + " " + UX.TTY.paint(effectiveProjectName, .accent) + " " + UX.TTY.paint("before watching", .dim))
        try await composeUp(originalPath: originalPath, projectName: effectiveProjectName, urls: urls)

        // Interactive "scope" : a sticky footer (service URLs + d/q keys)
        // redrawn at the bottom after every rebuild. Shared with compose up /
        // run / logs via UX.InteractiveFooter. Off-TTY it degrades to plain.
        let dir = projectDir
        let db = debounceMs
        let downPath = originalPath
        let downProj = effectiveProjectName
        let footerContent: @Sendable () -> [String] = {
            footerLines(
                header: [" " + UX.TTY.paint("→ Watching", .progress) + " " + UX.TTY.paint(dir, .accent)],
                services: urls.snapshot(),
                status: ["   " + UX.TTY.paint("FSEvents", .dim) + "   " + UX.TTY.paint("listening (debounce \(db)ms)", .dim)],
                detach: true, quit: true)
        }
        print("")
        let footer = InteractiveFooter()
        footer.start(
            footer: footerContent,
            onDetach: {
                // `d` → hand off to a detached background watch and exit.
                // Release OUR lock (and pid) first so the child can claim
                // them ; otherwise the child would fail acquireWatchLock and
                // exit, and detaching would silently do nothing.
                Self.releaseWatchLock(projectDir: dir)
                return (try? Self.detachAndExit(projectDir: dir, originalArgs: CommandLine.arguments)) ?? false
            },
            onQuit: {
                // `q` / Ctrl-C = quit for real : stop watching AND tear the
                // project down. (`d` above keeps it running in the background.)
                if let req = try? IPCRequest(type: .composeDown,
                                             payload: ComposeRequest(composePath: downPath, projectName: downProj)) {
                    _ = try? await IPCClient().send(req)
                }
                print("\n" + UX.TTY.paint("Stopped watching and tore the project down.", .dim))
            })

        let watcher = FSEventWatcher(path: projectDir, debounceMs: debounceMs)
        let stream = watcher.events()

        for await batch in stream {
            footer.clear()
            let head = UX.TTY.paint(UX.Icon.restart.rawValue, .restart)
            print(" \(head) " + UX.TTY.paint("Change detected", .restart) + " " + UX.TTY.paint("(\(batch.count) file\(batch.count > 1 ? "s" : ""))", .dim))
            let start = Date()
            do {
                try await composeUp(originalPath: originalPath, projectName: effectiveProjectName, withBuild: true, urls: urls)
                print(UX.ActionLine(
                    icon: .success, name: effectiveProjectName,
                    status: "Reloaded", trailing: UX.formatElapsed(Date().timeIntervalSince(start))
                ).render())
            } catch {
                UX.Failure.emit(
                    headline: "Reload failed",
                    reason: "\(error)",
                    hint: "check the compose file for syntax errors and try `cocker compose up --build` once manually"
                )
            }
            footer.refresh()  // keep the footer as the last thing on screen
        }
        footer.restore()
    }

    private static func pidFilePath(_ projectDir: String) -> String {
        projectDir + "/.cocker/watch.pid"
    }
    private static func logFilePath(_ projectDir: String) -> String {
        projectDir + "/.cocker/watch.log"
    }

    /// Returns the pid stored in `.cocker/watch.pid` if (and only if)
    /// the process is still alive. Self-cleans stale files from a
    /// previous crash so subsequent commands don't trip over a ghost.
    private static func livePID(projectDir: String) -> Int32? {
        let path = pidFilePath(projectDir)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        if kill(pid, 0) == 0 { return pid }
        // Process gone — stale pidfile.
        try? FileManager.default.removeItem(atPath: path)
        return nil
    }

    /// Held for the lifetime of a watcher process so the kernel keeps its
    /// flock on `.cocker/watch.lock`. Never closed on purpose — the lock is
    /// meant to persist until the process exits (at which point the OS drops
    /// it automatically, so a crashed watcher leaves nothing to clean up).
    private static var lockFD: Int32 = -1

    /// Acquire the single-watcher lock for `projectDir` with a non-blocking
    /// exclusive flock. Returns true iff we got it (another live watcher holds
    /// it → false). Kernel-managed, so it is immune to the stale/malformed/
    /// unlink races a pidfile-based claim is prone to.
    private static func acquireWatchLock(projectDir: String) -> Bool {
        try? FileManager.default.createDirectory(
            atPath: projectDir + "/.cocker", withIntermediateDirectories: true)
        let lockPath = projectDir + "/.cocker/watch.lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if fd < 0 { return false }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)  // someone else holds it
            return false
        }
        lockFD = fd  // keep open → lock held until this process exits
        return true
    }

    /// Drop the flock (and any pidfile we recorded) so another process can
    /// take over. Used when a foreground watcher hands off to a detached
    /// child via the `d` key — the child must be able to claim the lock.
    private static func releaseWatchLock(projectDir: String) {
        if lockFD >= 0 {
            close(lockFD)  // closing the fd releases the kernel flock
            lockFD = -1
        }
        try? FileManager.default.removeItem(atPath: pidFilePath(projectDir))
    }

    /// Terminate a detached background watcher (SIGTERM, escalate to
    /// SIGKILL after ~2s) and remove its pidfile. Returns the pid that was
    /// stopped, or nil if none was running. Shared by `--stop` and
    /// `--attach`.
    @discardableResult
    private static func stopDetached(projectDir: String) -> Int32? {
        guard let pid = Self.livePID(projectDir: projectDir) else { return nil }
        _ = kill(pid, SIGTERM)
        // Wait up to ~2s for it to actually exit, then SIGKILL if needed.
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            usleep(100_000)
        }
        if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        try? FileManager.default.removeItem(atPath: Self.pidFilePath(projectDir))
        return pid
    }

    private func handleStop(projectDir: String) throws {
        guard let pid = Self.stopDetached(projectDir: projectDir) else {
            print(" " + UX.TTY.paint("no watch running for this project", .dim, [.italic]))
            return
        }
        print(UX.ActionLine(
            icon: .success, name: "watch",
            status: "Stopped", trailing: "pid \(pid)"
        ).render())
    }

    private func handleStatus(projectDir: String) {
        if let pid = Self.livePID(projectDir: projectDir) {
            print(UX.ActionLine(
                icon: .success, name: "watch",
                status: "Running", trailing: "pid \(pid)"
            ).render())
            print("   " + UX.TTY.paint("log     :", .dim) + " " + Self.logFilePath(projectDir))
        } else {
            print(UX.ActionLine(
                icon: .item, name: "watch", status: "Not running"
            ).render())
        }
    }

    private func handleLogs(projectDir: String) throws {
        let log = Self.logFilePath(projectDir)
        if !FileManager.default.fileExists(atPath: log) {
            print("No log file yet at \(log).")
            return
        }
        // Only FOLLOW (`-f`) when a watch is actually running — otherwise
        // `tail -f` would block forever on a static file that nothing will
        // ever append to, hijacking the terminal (the exact "it won't give me
        // my terminal back" bug). With no live watch, dump the tail and exit.
        let following = Self.livePID(projectDir: projectDir) != nil
        // Reset SIGINT to its default so the exec'd `tail` always dies on
        // Ctrl-C, regardless of any SIG_IGN disposition inherited from an
        // interactive footer session earlier in this process.
        signal(SIGINT, SIG_DFL)
        // exec tail so the user gets the native scrolling experience. Swift
        // can't bridge varargs `execl`, so we materialize a NULL-terminated
        // argv array for `execv`.
        let argv: [UnsafeMutablePointer<CChar>?]
        if following {
            argv = [strdup("tail"), strdup("-f"), strdup(log), nil]
        } else {
            print(" " + UX.TTY.paint("no watch running — last log lines (not following)", .dim, [.italic]))
            argv = [strdup("tail"), strdup("-n"), strdup("200"), strdup(log), nil]
        }
        _ = execv("/usr/bin/tail", argv)
        throw CockerError.requestFailed("exec tail: \(String(cString: strerror(errno)))")
    }

    /// Fork the watch loop into a fully detached background process and
    /// exit cleanly. We re-exec the same `cocker compose watch` command
    /// minus the `-d/--detach` flag, with stdin closed and stdout/stderr
    /// redirected to `<projectDir>/.cocker/watch.log`. The child runs
    /// the normal foreground loop ; the parent prints the PID and the
    /// log path so the user can `tail -f` or `kill` it later.
    /// Returns `true` if a detached child was spawned (caller should exit),
    /// `false` if it refused because a watch is already running.
    @discardableResult
    private static func detachAndExit(projectDir: String, originalArgs: [String]) throws -> Bool {
        // Advisory fast-fail : if a watch is already registered, tell the user
        // now instead of spawning a child that would just lose the flock race
        // and exit. Authoritative exclusion is the child's acquireWatchLock()
        // in run() — this check is only for a friendly immediate message.
        if let existing = Self.livePID(projectDir: projectDir) {
            UX.Warning.emit(
                "watch is already running (pid \(existing))",
                note: "stop with `cocker compose watch --stop` or follow with `cocker compose watch --logs`"
            )
            return false
        }

        // Resolve the executable path before fork — Process.arguments
        // can be relative in some shells, and Foundation.Process doesn't
        // do a $PATH search the way exec*() would.
        let argv0 = originalArgs[0]
        let exePath: String
        if argv0.hasPrefix("/") {
            exePath = argv0
        } else {
            exePath = which(tool: (argv0 as NSString).lastPathComponent)
                ?? "/usr/bin/env"
        }

        // Strip `-d` / `--detach` so the child runs in foreground.
        let filtered = originalArgs.dropFirst().filter { $0 != "-d" && $0 != "--detach" }

        let logDir = projectDir + "/.cocker"
        try? FileManager.default.createDirectory(atPath: logDir,
                                                 withIntermediateDirectories: true)
        let logPath = Self.logFilePath(projectDir)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exePath)
        proc.arguments = Array(filtered)
        proc.currentDirectoryURL = URL(fileURLWithPath: projectDir)
        // Truncate the log on every fresh start so users don't trail
        // through stale output from yesterday's watch.
        FileManager.default.createFile(atPath: logPath, contents: nil)
        guard let logHandle = FileHandle(forWritingAtPath: logPath) else {
            throw CockerError.requestFailed("Could not open log file at \(logPath)")
        }
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        // Tell the child it is THE detached background watcher so it records
        // the pidfile once it wins the flock (foreground watchers don't).
        var childEnv = ProcessInfo.processInfo.environment
        childEnv["COCKER_WATCH_DETACHED_CHILD"] = "1"
        proc.environment = childEnv

        try proc.run()
        let pid = proc.processIdentifier
        // Wait for the child to actually win the flock and register, so we
        // never report a successful background start for a child that lost a
        // race (or hit a held lock) and exited. It registers its pid in the
        // pidfile from run() the moment it holds the lock.
        var registered = false
        for _ in 0..<40 {  // ~2s
            if Self.livePID(projectDir: projectDir) == pid { registered = true; break }
            if kill(pid, 0) != 0 { break }  // child already gone
            usleep(50_000)
        }
        guard registered else {
            UX.Warning.emit(
                "could not start background watch — another may already own this project",
                note: "check `cocker compose watch --status`"
            )
            return false
        }

        print(UX.ActionLine(
            icon: .success, name: "watch",
            status: "Started (background)", trailing: "pid \(pid)"
        ).render())
        print("   " + UX.TTY.paint("log     :", .dim) + " " + logPath)
        print("   " + UX.TTY.paint("status  :", .dim) + " cocker compose watch --status")
        print("   " + UX.TTY.paint("tail    :", .dim) + " cocker compose watch --logs")
        print("   " + UX.TTY.paint("attach  :", .dim) + " cocker compose watch --attach")
        print("   " + UX.TTY.paint("stop    :", .dim) + " cocker compose watch --stop")
        return true
    }

    /// Crude $PATH walk so `Process` can find the exe by basename when
    /// argv[0] was launched relatively. Falls back to nil — caller will
    /// substitute a safe default.
    private static func which(tool: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Call into the same staging + IPC pipeline `compose up` uses, but
    /// always with `--detach` semantics because we're driving from a
    /// daemon process (this CLI is the long-running parent of the watch
    /// loop ; we don't want the daemon stream to block our wait).
    private func composeUp(
        originalPath: String,
        projectName: String,
        withBuild: Bool = false,
        urls: ServiceURLs? = nil
    ) async throws {
        let stage = try await ICloudStaging.stageIfNeeded(originalPath: originalPath) { msg in
            print(" " + UX.TTY.paint("→ bird (iCloud) " + msg, .progress))
        }
        let client = IPCClient()
        let payload = ComposeRequest(
            composePath: stage.path,
            projectName: projectName,
            services: [],
            detach: true
        )
        let request = try IPCRequest(type: .composeUp, payload: payload)
        let fail = UX.FailFlag()
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout:
                print(event.data, terminator: "")
                urls?.capture(fromStdout: event.data)
            case .stderr: fputs(event.data, stderr)
            case .status: print(UX.TTY.paint(event.data, .progress))
            case .error:  fail.trip(); UX.Failure.emit(headline: event.data)
            }
        }
        try fail.throwIfTripped()
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

            // Wrap the FSEventStreamRef so the @Sendable termination
            // closure can carry it across actor boundaries. The stream
            // is single-owner (this scope creates + tears down) and
            // FSEventStream*() functions are themselves thread-safe.
            let streamBox = SendableFSEventStream(stream)
            continuation.onTermination = { _ in
                FSEventStreamStop(streamBox.stream)
                FSEventStreamInvalidate(streamBox.stream)
                FSEventStreamRelease(streamBox.stream)
            }
        }
    }
}

/// @unchecked Sendable wrapper for FSEventStreamRef so the cleanup
/// closure (which AsyncStream stores as @Sendable) can carry it across
/// actor boundaries. FSEventStream*() functions are thread-safe ; the
/// box itself only ever holds one stream owned by the producer scope.
private final class SendableFSEventStream: @unchecked Sendable {
    let stream: FSEventStreamRef
    init(_ stream: FSEventStreamRef) { self.stream = stream }
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
