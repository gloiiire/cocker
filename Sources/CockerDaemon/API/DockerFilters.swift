import Foundation
import CockerCore

/// Docker's `?filters=` query parameter, parsed and applied.
///
/// Every list endpoint used to ignore this parameter entirely, which is
/// destructive rather than merely incomplete: `docker compose` identifies the
/// containers it owns solely by `label=com.docker.compose.project=<name>`, so
/// it received every container on the host and treated the others as orphans
/// to recreate or remove. `docker compose down` in one project could tear
/// down another's. Dev Containers has the same failure mode via
/// `devcontainer.local_folder`.
///
/// The wire format is a URL-encoded JSON object whose values are arrays of
/// strings: `{"label":["com.docker.compose.project=web"],"status":["running"]}`.
/// Older clients send `{"dangling":{"true":true}}` (a set-shaped map) for the
/// same thing, so both encodings are accepted.
///
/// Values within one key are OR'd; separate keys are AND'd. That is Docker's
/// rule, and it is what makes `--filter label=a --filter label=b` mean "both
/// labels", which compose relies on.
struct DockerFilters {
    private let raw: [String: [String]]

    var isEmpty: Bool { raw.isEmpty }

    private init(raw: [String: [String]]) { self.raw = raw }

    /// Parse the query parameter. A missing or empty value means "match
    /// everything". Malformed JSON is reported rather than silently treated
    /// as no filter — returning the full list to a client that asked for a
    /// subset is the bug this type exists to fix.
    static func parse(_ value: String?) throws -> DockerFilters {
        guard let value, !value.isEmpty else { return DockerFilters(raw: [:]) }
        let decoded = value.removingPercentEncoding ?? value
        guard let data = decoded.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw FilterError.malformed
        }

        var parsed: [String: [String]] = [:]
        for (key, rawValue) in object {
            if let list = rawValue as? [String] {
                parsed[key] = list
            } else if let set = rawValue as? [String: Bool] {
                // Legacy set encoding: {"dangling":{"true":true}}. Only the
                // keys mapped to true are active.
                parsed[key] = set.filter { $0.value }.keys.sorted()
            } else if let single = rawValue as? String {
                parsed[key] = [single]
            } else {
                throw FilterError.malformed
            }
        }
        return DockerFilters(raw: parsed.filter { !$0.value.isEmpty })
    }

    enum FilterError: Error, CustomStringConvertible {
        case malformed
        case unsupported(key: String, supported: [String])

        var description: String {
            switch self {
            case .malformed:
                return "invalid filter: expected a JSON object of string arrays"
            case let .unsupported(key, supported):
                return "invalid filter '\(key)' (supported: \(supported.sorted().joined(separator: ", ")))"
            }
        }
    }

    /// Reject filter keys this endpoint doesn't implement.
    ///
    /// Docker itself 400s on an unknown filter, and answering loudly is the
    /// only safe option here: a client that asked to narrow a list and
    /// silently got everything may then act destructively on the surplus.
    func requireSupported(_ supported: [String]) throws {
        for key in raw.keys where !supported.contains(key) {
            throw FilterError.unsupported(key: key, supported: supported)
        }
    }

    func values(_ key: String) -> [String] { raw[key] ?? [] }

    // MARK: - Shared predicates

    /// `label=key` (presence) or `label=key=value` (exact). All supplied
    /// labels must match.
    func matchesLabels(_ labels: [String: String]) -> Bool {
        for spec in values("label") {
            if let separator = spec.firstIndex(of: "=") {
                let key = String(spec[spec.startIndex..<separator])
                let value = String(spec[spec.index(after: separator)...])
                guard labels[key] == value else { return false }
            } else {
                guard labels[spec] != nil else { return false }
            }
        }
        return true
    }

    /// Docker matches names as a substring (its own CLI passes them through
    /// as regex fragments; substring is the behaviour clients depend on).
    /// A leading `/` is stripped — Docker reports container names with one.
    func matchesName(_ name: String, key: String = "name") -> Bool {
        let wanted = values(key)
        if wanted.isEmpty { return true }
        return wanted.contains { name.contains($0.hasPrefix("/") ? String($0.dropFirst()) : $0) }
    }

    /// Ids match on prefix, so short ids work like everywhere else.
    func matchesID(_ id: String, key: String = "id") -> Bool {
        let wanted = values(key)
        if wanted.isEmpty { return true }
        return wanted.contains { id.hasPrefix($0) }
    }

    func matchesExact(_ actual: String, key: String) -> Bool {
        let wanted = values(key)
        if wanted.isEmpty { return true }
        return wanted.contains(actual)
    }

    /// `dangling=true` / `dangling=false`. Absent means "don't care".
    func danglingWanted() -> Bool? {
        guard let value = values("dangling").first else { return nil }
        return value == "true" || value == "1"
    }
}

// MARK: - Per-resource application

extension DockerFilters {
    // Only keys that are genuinely applied below. `before`/`since` are
    // deliberately absent: listing them here without implementing them would
    // recreate exactly the silent-wrong-result this type exists to prevent.
    static let containerKeys = ["id", "name", "label", "status", "ancestor", "health", "exited"]
    static let imageKeys = ["dangling", "label", "reference"]
    static let volumeKeys = ["name", "driver", "label", "dangling"]
    static let networkKeys = ["id", "name", "driver", "scope", "type", "label"]

    /// Docker's status vocabulary differs from ours: it says `exited` where
    /// cocker's state machine says `stopped`. Filtering on the raw enum would
    /// make `docker ps --filter status=exited` return nothing.
    static func dockerStatusName(_ status: ContainerStatus) -> String {
        switch status {
        case .stopped: return "exited"
        case .created: return "created"
        case .running: return "running"
        case .paused: return "paused"
        case .restarting: return "restarting"
        case .dead: return "dead"
        }
    }

    func matches(container: Container) -> Bool {
        guard matchesID(container.id) else { return false }
        guard matchesName(container.name) else { return false }
        guard matchesLabels(container.labels) else { return false }
        guard matchesExact(Self.dockerStatusName(container.status), key: "status") else { return false }
        guard matchesExact(container.healthStatus.rawValue, key: "health") else { return false }
        // `ancestor` is the image the container was created from. Docker
        // accepts a reference or an id prefix.
        let ancestors = values("ancestor")
        if !ancestors.isEmpty {
            guard ancestors.contains(where: { container.image == $0 || container.image.hasPrefix($0) })
            else { return false }
        }
        // `exited=<code>` narrows to containers that stopped with that code.
        let exitCodes = values("exited")
        if !exitCodes.isEmpty {
            guard let code = container.exitCode,
                  exitCodes.contains(String(code)) else { return false }
        }
        return true
    }

    func matches(image: ImageInfo) -> Bool {
        guard matchesLabels(image.labels) else { return false }
        let reference = "\(image.repository):\(image.tag)"
        if let wantDangling = danglingWanted() {
            // Docker calls an image dangling when it carries no usable tag.
            let isDangling = image.tag == "<none>" || image.tag.isEmpty
                || image.repository == "<none>" || image.repository.isEmpty
            guard isDangling == wantDangling else { return false }
        }
        let references = values("reference")
        if !references.isEmpty {
            guard references.contains(where: { Self.matchesReferencePattern(reference, pattern: $0) })
            else { return false }
        }
        return true
    }

    func matches(volume: VolumeInfo) -> Bool {
        guard matchesName(volume.name) else { return false }
        guard matchesLabels(volume.labels) else { return false }
        guard matchesExact(volume.driver, key: "driver") else { return false }
        return true
    }

    func matches(network: NetworkInfo) -> Bool {
        guard matchesID(network.id) else { return false }
        guard matchesName(network.name) else { return false }
        guard matchesExact(network.driver.rawValue, key: "driver") else { return false }
        // Every cocker network is host-local and user-defined unless it's the
        // default bridge; report that vocabulary rather than dropping the key.
        guard matchesExact("local", key: "scope") else { return false }
        let types = values("type")
        if !types.isEmpty {
            let kind = network.name == "bridge" ? "builtin" : "custom"
            guard types.contains(kind) else { return false }
        }
        return true
    }

    /// `reference=nginx`, `reference=nginx:1.2`, `reference=ngin*`. Docker
    /// treats a reference without a tag as matching every tag of that repo.
    static func matchesReferencePattern(_ reference: String, pattern: String) -> Bool {
        if pattern.contains("*") {
            let parts = pattern.components(separatedBy: "*")
            var cursor = reference.startIndex
            for (index, part) in parts.enumerated() where !part.isEmpty {
                guard let found = reference.range(of: part, range: cursor..<reference.endIndex)
                else { return false }
                // A pattern not starting with `*` must match at the very start.
                if index == 0 && found.lowerBound != reference.startIndex { return false }
                cursor = found.upperBound
            }
            if let last = parts.last, !last.isEmpty, !reference.hasSuffix(last) { return false }
            return true
        }
        if pattern.contains(":") { return reference == pattern }
        // Bare repo name matches any tag of it.
        return reference == pattern || reference.hasPrefix("\(pattern):")
    }
}
