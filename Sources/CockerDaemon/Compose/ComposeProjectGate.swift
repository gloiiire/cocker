import Foundation

/// FIFO async mutex keyed by normalized Compose project name. Swift actors are
/// reentrant across awaits, so actor isolation alone does not stop `watch`,
/// `restart`, and a manual `up` from replacing the same project concurrently.
actor ComposeProjectGate {
    private var locked: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func withLock<T: Sendable>(
        project: String,
        operation: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(project)
        defer { release(project) }
        return try await operation()
    }

    private func acquire(_ project: String) async {
        if locked.insert(project).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[project, default: []].append(continuation)
        }
    }

    private func release(_ project: String) {
        if var queue = waiters[project], !queue.isEmpty {
            let next = queue.removeFirst()
            if queue.isEmpty { waiters.removeValue(forKey: project) }
            else { waiters[project] = queue }
            next.resume()
        } else {
            locked.remove(project)
        }
    }
}
