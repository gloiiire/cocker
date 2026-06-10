import Foundation

/// Inspect iCloud Drive materialization state for a directory tree.
///
/// `NSMetadataQuery` (the canonical Apple API for this) requires
/// `com.apple.developer.icloud-container-identifiers` entitlements ;
/// CLI binaries without an iCloud container get **zero results** even
/// when iCloud is healthy. So we walk the FS manually and consult
/// `URLResourceValues.ubiquitousItemDownloadingStatus` per file —
/// that read goes straight to the per-file extended attribute that
/// `bird` writes when it places a dataless stub. No entitlement
/// needed, no IPC to bird, no risk of EDEADLK because we're only
/// reading metadata, never opening the file.
struct ICloudInspector {

    struct State {
        var totalFiles: Int = 0
        var downloaded: Int = 0    // ready to read
        var current: Int = 0        // ready AND up-to-date with cloud
        var notDownloaded: Int = 0 // dataless placeholder
        var downloading: Int = 0   // bird is fetching right now
        var totalBytes: Int64 = 0
        var pendingBytes: Int64 = 0
        /// 0.0…1.0 averaged across files currently downloading. nil
        /// when nothing is in flight (avoid showing misleading 0%).
        var averageDownloadProgress: Double?

        var isFullyLocal: Bool { notDownloaded == 0 && downloading == 0 }
        var needsPreFetch: Bool { notDownloaded > 0 || downloading > 0 }
    }

    /// Walk `dir` and classify every regular file by iCloud download
    /// status. Returns a sentinel `State()` if the path doesn't exist.
    /// Always honors `COCKER_ICLOUD_TIMEOUT` (default 30s) to guard
    /// against pathological cases (bird wedged on a particular file).
    static func inspect(dir: String, timeout: TimeInterval = 30) async -> State {
        let envTimeout = ProcessInfo.processInfo.environment["COCKER_ICLOUD_TIMEOUT"]
            .flatMap { TimeInterval($0) }
        let effectiveTimeout = envTimeout ?? timeout

        return await withTaskGroup(of: State?.self) { group in
            group.addTask { return walk(dir: dir) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result ?? State()
            }
            return State()
        }
    }

    /// Synchronous walker. Kept private and routed through `inspect`
    /// to apply the timeout safety net.
    private static func walk(dir: String) -> State {
        let baseURL = URL(fileURLWithPath: dir)
        var state = State()
        var progressSum: Double = 0
        var progressCount = 0

        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
            // .ubiquitousItemPercentDownloadedKey isn't an URLResourceKey
            // (only exposed via NSMetadataItem), so we can't surface it
            // here. The downloading count + a partial materialization
            // ratio is enough signal for UX.
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return state
        }

        // Hardcoded skip set : same dirs ICloudStaging excludes for
        // rsync. No point counting files inside .git / node_modules
        // when the staging pass is going to drop them anyway, and
        // walking them on iCloud is expensive (.git can be thousands
        // of small pack/index files).
        let skipNames: Set<String> = [".git", "node_modules", ".DS_Store"]

        for case let url as URL in enumerator {
            let lastComp = url.lastPathComponent
            if skipNames.contains(lastComp) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            state.totalFiles += 1
            let size = Int64(values.fileSize ?? 0)
            state.totalBytes += size

            // URLUbiquitousItemDownloadingStatus is a typed enum on the
            // resource values bag.
            switch values.ubiquitousItemDownloadingStatus {
            case .current:
                state.current += 1
                state.downloaded += 1
            case .downloaded:
                state.downloaded += 1
            case .notDownloaded:
                state.notDownloaded += 1
                state.pendingBytes += size
            case .none:
                // Not an iCloud-managed file (locally-created, never
                // synced) — count as downloaded since reading won't
                // trigger any bird interaction.
                state.downloaded += 1
            case .some(_):
                // Future enum case — assume not downloaded to err safe.
                state.notDownloaded += 1
                state.pendingBytes += size
            }

            if values.ubiquitousItemIsDownloading == true {
                state.downloading += 1
                // Without percent-downloaded we approximate progress as
                // 50% (item is in flight, somewhere between 0 and 100).
                // Cosmetic only.
                progressSum += 0.5
                progressCount += 1
            }
        }

        if progressCount > 0 {
            state.averageDownloadProgress = progressSum / Double(progressCount)
        }
        return state
    }
}
