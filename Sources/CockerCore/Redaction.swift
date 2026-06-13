import Foundation

/// **S2** : Container env vars routinely carry runtime secrets — DB
/// passwords, API tokens, S3 credentials. They live in `state.json`
/// (0o600 — local-user only) but they also flow through `cocker inspect`
/// to anyone with daemon-socket access AND through whatever JSON the
/// Docker API layer surfaces. The helpers here let callers redact those
/// values to "***" before display, without losing information about which
/// keys were present.
///
/// We pattern-match the *key* rather than the value because there's no
/// reliable way to tell a 32-char DB password from a 32-char container
/// SHA. The match list is intentionally conservative ; false positives
/// (masking a non-secret) only confuse a user, while false negatives
/// (failing to mask a real secret) leak it.
public enum SecretRedactor {
    /// Substrings considered "always sensitive" when found in an env key
    /// (case-insensitive). A real env var named `MY_PASSWORD_HINT` is
    /// masked too — false positive, acceptable.
    public static let sensitiveKeySubstrings: [String] = [
        "PASSWORD", "PASSWD", "SECRET", "TOKEN", "API_KEY", "APIKEY",
        "PRIVATE_KEY", "PRIVKEY", "CREDENTIAL", "SESSION", "AUTH",
        "TWILIO", "STRIPE", "AWS_SECRET", "SLACK_TOKEN", "DATABASE_URL",
        "DSN", "WEBHOOK", "OAUTH",
    ]

    public static func isSensitive(_ key: String) -> Bool {
        let upper = key.uppercased()
        return sensitiveKeySubstrings.contains { upper.contains($0) }
    }

    /// Return a new map where the values for sensitive keys are replaced
    /// by `replacement`. Keys are preserved verbatim so the user can still
    /// audit which env vars exist on a container.
    public static func redact(
        _ env: [String: String],
        replacement: String = "***"
    ) -> [String: String] {
        var out = env
        for k in env.keys where isSensitive(k) {
            out[k] = replacement
        }
        return out
    }
}

extension Container {
    /// Container clone suitable for display / logging contexts where the
    /// caller doesn't want to leak runtime secrets. Mirrors `docker
    /// inspect --no-secrets` semantics (which doesn't exist upstream yet
    /// but is the conventional spelling).
    public func redactedForDisplay() -> Container {
        var copy = self
        copy.env = SecretRedactor.redact(env)
        return copy
    }
}
