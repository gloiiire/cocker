import Foundation

// Pure name → IP resolution against a known set of containers. The actual
// DNS server (DNSServer in CockerDaemon) wraps this with caching, wire
// encoding, and transport. Separating the resolver makes the matching rules
// unit-testable without spinning up a UDP socket or a state store.
//
// Cocker resolves a name against any of :
//   - container.name             ("srv-a")
//   - container service alias    (com.cocker.service compose label)
//   - container short ID         (first 12 chars of container.id)
//   - container.hostname
//   - any name in com.cocker.aliases (comma-separated)
//
// Each candidate name is normalised first :
//   - strip trailing dot (FQDN form)
//   - strip ".cocker" domain suffix
//   - try the first DNS label alone ("web.default" → also "web")

public enum DNSNameResolver {
    public static let cockerDomain = "cocker"

    /// Resolve an A (IPv4) record. Prefers `container.cockerIP` (the L2 switch
    /// fabric address, reachable from peer containers) over `container.ip`
    /// (the vmnet NAT address, only reachable from the host).
    public static func resolveA(name: String, in containers: [Container]) -> String? {
        let candidates = normalizedNames(from: name)
        for container in containers {
            guard let ip = container.cockerIP ?? container.ip else { continue }
            if matches(container, candidates: candidates) { return ip }
        }
        return nil
    }

    /// Whether `name` belongs to one of these containers, whatever addresses
    /// it happens to have.
    ///
    /// This replaced `resolveAAAA`, which answered every IPv6 query for a
    /// container name with `fd00:c0c4::<hash-of-container-id>` — an address
    /// cocker computed, stored and served, and configured on no interface in
    /// any guest.
    ///
    /// The caller needs "is this one of ours?" separately from "what is its
    /// address?", because the honest AAAA answer for a container is NODATA:
    /// the name exists, that record type does not. Getting that distinction
    /// wrong is not theoretical — see `DNSQueryProcessor.process`, where both
    /// of the obvious alternatives break a real client.
    public static func matchesContainer(name: String, in containers: [Container]) -> Bool {
        let candidates = normalizedNames(from: name)
        return containers.contains { matches($0, candidates: candidates) }
    }

    /// All the equivalent forms of a queried name we'll accept.
    public static func normalizedNames(from name: String) -> Set<String> {
        var candidates = Set<String>()
        candidates.insert(name)

        let withoutCocker = name.hasSuffix(".\(cockerDomain)")
            ? String(name.dropLast(cockerDomain.count + 1))
            : name
        candidates.insert(withoutCocker)

        let firstPart = withoutCocker.split(separator: ".").first.map(String.init) ?? withoutCocker
        candidates.insert(firstPart)

        let withoutDot = name.hasSuffix(".") ? String(name.dropLast()) : name
        candidates.insert(withoutDot)

        return candidates
    }

    // MARK: - Matching

    /// Does any of the container's identifiers appear in the candidate set ?
    private static func matches(_ container: Container, candidates: Set<String>) -> Bool {
        if candidates.contains(container.name) { return true }
        if let service = container.labels["com.cocker.service"],
           candidates.contains(service) { return true }
        if candidates.contains(String(container.id.prefix(12))) { return true }
        if candidates.contains(container.hostname) { return true }
        if let aliases = container.labels["com.cocker.aliases"]?.split(separator: ",") {
            for alias in aliases {
                if candidates.contains(String(alias).trimmingCharacters(in: .whitespaces)) {
                    return true
                }
            }
        }
        return false
    }
}
