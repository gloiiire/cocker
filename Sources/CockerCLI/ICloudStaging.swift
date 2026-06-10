import CockerCore
import CryptoKit
import Foundation

/// Stage iCloud-resident project directories to a local cache so the
/// daemon never has to touch `bird`-managed files. cockerd reads files
/// from its own process, where iCloud's coordinator deadlocks (`EDEADLK`
/// after the first concurrent access) ; the CLI runs as a normal user
/// process and CAN read iCloud cleanly via `rsync`, so we do the copy
/// here and hand the daemon a `/tmp`-style path.
///
/// Caching is stable per project: the staging dir is rooted at
/// `~/Library/Caches/cocker/staging/<sha256(projectDir)>` so a second
/// `compose up` of the same project re-runs `rsync -a --delete`
/// incrementally and finishes in milliseconds instead of seconds (only
/// changed files are re-read from iCloud).
///
/// Also applies to non-iCloud-but-large dirs only when the user opts in
/// via `COCKER_FORCE_STAGE=1`. The detection by default is conservative
/// — substring on `Mobile Documents/com~apple~CloudDocs/` plus a check
/// for the `com.apple.fileprovider.fpfs#PF` xattr that "Desktop &
/// Documents Folders" sync attaches to ~/Documents and ~/Desktop when
/// they're iCloud-managed without being under Mobile Documents.
struct ICloudStaging {
    /// Path the daemon should use as compose file / build context.
    let path: String
    /// Where the staged copy lives. `nil` if no staging was needed.
    let stagingRoot: URL?

    static func stageIfNeeded(
        originalPath: String,
        log: (String) -> Void = { _ in }
    ) async throws -> ICloudStaging {
        let projectDir = (originalPath as NSString).deletingLastPathComponent
        let fileName = (originalPath as NSString).lastPathComponent

        guard isICloudPath(projectDir) else {
            return ICloudStaging(path: originalPath, stagingRoot: nil)
        }

        let stagingRoot = cacheDir(for: projectDir)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        // Inspect which files are Materialized / Dataless / Downloading
        // BEFORE we ask rsync to read the tree. Lets us :
        //   1. Skip pre-fetch entirely when everything's local (gain 1-3s).
        //   2. Show a real "N / M downloaded" progress instead of a
        //      spinner.
        //   3. Detect bird being offline early instead of hanging rsync.
        let state = await ICloudInspector.inspect(dir: projectDir)
        if state.totalFiles == 0 {
            log("iCloud index unavailable, syncing without pre-fetch hint…")
        } else if state.needsPreFetch {
            log("iCloud project has \(state.notDownloaded) dataless file(s) (\(formatBytes(state.pendingBytes))), materializing transparently…")
            try await materializeICloud(dir: projectDir, log: log)
        } else {
            log("iCloud project is fully local (\(state.totalFiles) files, \(formatBytes(state.totalBytes))), skipping pre-fetch.")
        }

        // Write a temp exclude file combining hard defaults (.git,
        // node_modules, etc.) with every .dockerignore / .cockerignore
        // found in the project. Reduces iCloud read pressure by a
        // factor of 10x-100x for typical Node / Python projects.
        let excludeFile = stagingRoot.appendingPathComponent(".cocker-rsync-exclude").path
        let excludePatterns = collectIgnorePatterns(projectDir: projectDir)
        try excludePatterns.joined(separator: "\n").write(
            toFile: excludeFile, atomically: true, encoding: .utf8)

        // `rsync -a --delete` makes the staged dir an incremental mirror
        // of the source. First run is a full copy ; subsequent runs only
        // transfer paths whose mtime/size changed, which on a typical
        // re-run is just the files the user edited (1-10 files instead
        // of hundreds), bypassing iCloud's bird wedge entirely.
        let isFirstRun = !FileManager.default.fileExists(
            atPath: stagingRoot.appendingPathComponent(fileName).path)
        log(isFirstRun
            ? "Staging iCloud project to local cache (first run, may take a moment)…"
            : "Syncing iCloud project changes to cache…")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        proc.arguments = [
            "-a", "--delete",
            "--exclude=.cocker-rsync-exclude",
            "--exclude-from=\(excludeFile)",
            projectDir + "/", stagingRoot.path + "/",
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(atPath: excludeFile)
        if proc.terminationStatus != 0 {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let msg = String(data: errData, encoding: .utf8) ?? ""
            throw CockerError.buildFailed("iCloud staging failed: \(msg)")
        }

        return ICloudStaging(
            path: stagingRoot.appendingPathComponent(fileName).path,
            stagingRoot: stagingRoot
        )
    }

    // MARK: - iCloud detection

    static func isICloudPath(_ path: String) -> Bool {
        // Force-stage escape hatch — useful for testing the staging code
        // path on a non-iCloud dir, or for users with custom iCloud-like
        // setups (e.g. Maestral / Dropbox file providers).
        if ProcessInfo.processInfo.environment["COCKER_FORCE_STAGE"] == "1" {
            return true
        }
        // Mobile Documents → the canonical iCloud Drive container.
        if path.contains("/Mobile Documents/com~apple~CloudDocs/") {
            return true
        }
        // "Desktop & Documents Folders" sync : ~/Documents and ~/Desktop
        // get an `com.apple.fileprovider.fpfs#PF` extended attribute on
        // every entry when iCloud is managing them. Check the path's
        // first existing ancestor.
        var probe = URL(fileURLWithPath: path)
        while probe.path != "/" {
            if FileManager.default.fileExists(atPath: probe.path) {
                if hasICloudFileProviderXattr(probe.path) {
                    return true
                }
                break
            }
            probe.deleteLastPathComponent()
        }
        return false
    }

    private static func hasICloudFileProviderXattr(_ path: String) -> Bool {
        let bufSize = 4096
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        let n = listxattr(path, buf, bufSize, 0)
        if n <= 0 { return false }
        var i = 0
        while i < n {
            let name = String(cString: buf.advanced(by: i))
            if name.hasPrefix("com.apple.fileprovider") {
                return true
            }
            i += name.utf8.count + 1
        }
        return false
    }

    // MARK: - Cache layout

    /// Stable cache dir keyed by the source project path. We deliberately
    /// hash instead of mirroring the path under /tmp so the staging dir
    /// stays short and predictable, doesn't blow up `PATH_MAX` on deeply
    /// nested iCloud projects, and survives across cocker upgrades.
    private static func cacheDir(for projectDir: String) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base = home
            .appendingPathComponent("Library/Caches/cocker/staging", isDirectory: true)
        let hash = sha256Hex(projectDir).prefix(16)
        // Suffix with the basename so cache entries are still inspectable
        // by hand — `ls ~/Library/Caches/cocker/staging` shows project
        // names rather than opaque hashes.
        let basename = (projectDir as NSString).lastPathComponent
        let sanitized = basename.replacingOccurrences(of: " ", with: "_")
        return base.appendingPathComponent("\(sanitized)-\(hash)", isDirectory: true)
    }

    private static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Maintenance

    /// Wipe the staging cache. Wired up to `cocker prune --staging` so
    /// users can recover disk after deleting projects. Returns the
    /// number of bytes reclaimed.
    @discardableResult
    static func clearCache() -> UInt64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base = home.appendingPathComponent("Library/Caches/cocker/staging")
        var freed: UInt64 = 0
        if let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0
                freed += UInt64(size)
            }
        }
        try? FileManager.default.removeItem(at: base)
        return freed
    }

    // MARK: - Ignore patterns

    /// Combine hardcoded defaults with every `.dockerignore` /
    /// `.cockerignore` found in the tree, anchored to the dir that holds
    /// each file. Drives `rsync --exclude-from`.
    private static func collectIgnorePatterns(projectDir: String) -> [String] {
        var patterns: [String] = [
            ".git", ".git/**",
            "node_modules", "node_modules/**",
            ".DS_Store",
            // iCloud's own scratch / placeholder files. `.icloud` ghost
            // files in particular are NEVER what the user means to
            // bundle into the image — they're sentinel paths for
            // not-yet-downloaded content.
            "*.icloud",
            ".DocumentRevisions-V100", ".Spotlight-V100", ".Trashes",
            ".fseventsd", ".TemporaryItems",
        ]
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: projectDir) else {
            return patterns
        }
        for case let path as String in enumerator {
            let basename = (path as NSString).lastPathComponent
            guard basename == ".dockerignore" || basename == ".cockerignore" else {
                continue
            }
            let full = projectDir + "/" + path
            guard let content = try? String(contentsOfFile: full, encoding: .utf8) else {
                continue
            }
            let dirPrefix = (path as NSString).deletingLastPathComponent
            for line in content.split(separator: "\n") {
                let p = line.trimmingCharacters(in: .whitespaces)
                if p.isEmpty || p.hasPrefix("#") { continue }
                let isNegate = p.hasPrefix("!")
                let raw = isNegate ? String(p.dropFirst()) : p
                let anchored = dirPrefix.isEmpty ? raw : "\(dirPrefix)/\(raw)"
                patterns.append(isNegate ? "+ \(anchored)" : anchored)
            }
        }
        return patterns
    }

    // MARK: - Transparent materialization

    /// Walk the project tree and force-download every Dataless file via
    /// `URL.startDownloadingUbiquitousItem(at:)`. Then poll until bird
    /// reports everything as `current` / `downloaded`, surfacing live
    /// progress to the user.
    ///
    /// Why this beats `brctl download <dir>` :
    ///   - We can show `12 / 127 files materialized` per poll tick.
    ///   - We respect `.dockerignore` (skip downloading node_modules even
    ///     if iCloud thinks they're dataless).
    ///   - `startDownloadingUbiquitousItem` is a per-URL Foundation API ;
    ///     each call is an isolated request to bird. If bird wedges on one
    ///     file, the rest still queue and the inspector loop tells us
    ///     exactly which file is stuck.
    ///   - No subprocess fork overhead.
    private static func materializeICloud(
        dir: String,
        log: (String) -> Void
    ) async throws {
        // Collect every Dataless URL, honoring the same ignore patterns
        // rsync would apply — no point pulling node_modules from iCloud
        // just to throw it out in the next step.
        let ignorePatterns = collectIgnorePatterns(projectDir: dir)
        let dataless = collectDatalessURLs(dir: dir, ignore: ignorePatterns)
        if dataless.isEmpty {
            log("No materialization needed after ignore filtering.")
            return
        }

        let total = dataless.count
        log("Queueing download of \(total) file(s) with bird…")
        for url in dataless {
            // This is the documented Apple API : it tells the File
            // Provider extension (bird, for iCloud) to start a
            // background download. Returns immediately. Throws only on
            // malformed URL / non-ubiquitous container.
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        // Poll loop — every 500ms re-inspect, log progress, exit when
        // either everything is local or we time out. The timeout is
        // generous (5 min) because a fresh checkout on a slow link can
        // legitimately take minutes to materialize a multi-MB project.
        let deadline = Date().addingTimeInterval(300)
        var lastPctReported = -1
        while Date() < deadline {
            let snapshot = await ICloudInspector.inspect(dir: dir, timeout: 10)
            if snapshot.totalFiles == 0 { break }
            let done = snapshot.downloaded
            let pct = Int((Double(done) / Double(max(snapshot.totalFiles, 1))) * 100)
            if pct != lastPctReported && pct % 10 == 0 {
                log("  \(pct)% materialized (\(done) / \(snapshot.totalFiles))")
                lastPctReported = pct
            }
            if !snapshot.needsPreFetch {
                log("✓ All files materialized.")
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("⚠️  Materialization deadline reached ; rsync will pull whatever's still missing.")
    }

    /// Walk the project tree and return every URL whose ubiquitous
    /// status is `.notDownloaded`, skipping anything matching the ignore
    /// patterns. Kept synchronous because the walk is cheap and we
    /// already hold the user's TTY.
    private static func collectDatalessURLs(dir: String, ignore: [String]) -> [URL] {
        var urls: [URL] = []
        let baseURL = URL(fileURLWithPath: dir)
        let skipNames: Set<String> = [".git", "node_modules", ".DS_Store"]
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return urls }

        for case let url as URL in enumerator {
            if skipNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            if values.ubiquitousItemDownloadingStatus == .notDownloaded {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - Formatting

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Subprocess helper

    @discardableResult
    private static func runQuietly(_ executable: String, _ args: [String]) throws -> Int32 {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return -1
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus
    }
}
