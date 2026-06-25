import Foundation

/// Validates user-supplied *resource names* (secret / config / volume names)
/// before they are used as a single filesystem path component.
///
/// This is the **name** counterpart to `PathConfinement`, which guards
/// multi-segment **paths**. A name is stricter : it must be a *single*
/// path component, so `/` is forbidden outright and there is no notion of
/// "escaping the root" to reason about — a valid name simply cannot be a
/// path.
///
/// The danger we close : code like
/// `secretsDir().appendingPathComponent(name)` does **zero** lexical
/// validation. With `name == "../escape"` the resulting URL points outside
/// the directory the caller believed it was confined to, and the daemon
/// then `mkdir`s / `mke2fs`es / writes there. See `VolumeManager.create`
/// and `SecretCommands`.
///
/// We use an **allowlist**, not a blocklist : we accept only characters we
/// know are safe rather than trying to enumerate every dangerous one (you
/// always forget one). The rule mirrors Docker's own volume-name grammar
/// `[a-zA-Z0-9][a-zA-Z0-9_.-]*` :
///
///   - first character must be alphanumeric — this alone rejects `.`, `..`,
///     `.hidden`, and `-leadingdash`;
///   - remaining characters may only be `[a-zA-Z0-9_.-]` — which forbids
///     `/` (no sub-paths) and the NUL byte (Foundation truncates at NUL, so
///     `"a\0/../escape"` would otherwise smuggle a traversal through).
public enum ResourceName {

    /// Upper bound on name length. 255 is the per-component limit on APFS /
    /// most Unix filesystems ; a name longer than this could never become a
    /// real file anyway, and bounding it keeps error messages and IPC
    /// payloads sane.
    public static let maxLength = 255

    /// Throw `CockerError.invalidResourceName` if `name` is not a safe,
    /// single-component resource name. `kind` is only used to phrase the
    /// error ("secret", "config", "volume").
    public static func validate(_ name: String, kind: String) throws {
        func reject(_ reason: String) -> CockerError {
            .invalidResourceName(kind: kind, name: name, reason: reason)
        }

        guard !name.isEmpty else {
            throw reject("must not be empty")
        }
        guard name.count <= maxLength else {
            throw reject("must be at most \(maxLength) characters")
        }

        // Validate each Unicode scalar against the allowlist. The first
        // scalar has the stricter alphanumeric rule.
        for (index, scalar) in name.unicodeScalars.enumerated() {
            let isAlphanumeric = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")

            if index == 0 {
                guard isAlphanumeric else {
                    throw reject("must start with a letter or digit "
                        + "(this also blocks '.', '..' and path traversal)")
                }
            } else {
                let isAllowed = isAlphanumeric
                    || scalar == "." || scalar == "_" || scalar == "-"
                guard isAllowed else {
                    throw reject("may only contain letters, digits, "
                        + "'.', '_' and '-' (no '/', spaces or control characters)")
                }
            }
        }
    }
}
