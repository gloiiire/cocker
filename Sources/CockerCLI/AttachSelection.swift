import Foundation

// Which services `compose up` should stream logs from.
//
// Docker's model, which this mirrors:
//   - attached (foreground) `up` aggregates the output of every service,
//     exactly like `compose logs --follow`;
//   - `--attach svc` RESTRICTS that set — it does not enable attaching,
//     which is already the default;
//   - `--no-attach svc` excludes noisy services from the aggregate;
//   - `-d` detaches entirely and streams nothing.
//
// Keeping the selection here, away from any I/O, means the rules can be
// tested exhaustively rather than inferred from a running stack.
public enum AttachSelection {

    /// Services whose logs should be streamed.
    ///
    /// - Parameters:
    ///   - all: every service in the project (already profile-filtered).
    ///   - attach: `--attach` values. Empty means "no restriction".
    ///   - noAttach: `--no-attach` values, applied after `attach`.
    /// - Returns: the services to stream, in the order of `all` so output
    ///   ordering stays stable across runs.
    public static func resolve(all: [String],
                               attach: [String],
                               noAttach: [String]) -> [String] {
        // `--attach` restricts; absent, everything is attached.
        let restricted = attach.isEmpty
            ? all
            : all.filter { attach.contains($0) }
        guard !noAttach.isEmpty else { return restricted }
        return restricted.filter { !noAttach.contains($0) }
    }

    /// Names in `attach` / `noAttach` that match no service in the project.
    ///
    /// Docker fails on an unknown `--attach` target rather than silently
    /// streaming nothing, and so should we : a typo that quietly produces
    /// an empty log view is far more confusing than an error.
    public static func unknownServices(all: [String],
                                       attach: [String],
                                       noAttach: [String]) -> [String] {
        let known = Set(all)
        var unknown: [String] = []
        for name in attach + noAttach where !known.contains(name) {
            if !unknown.contains(name) { unknown.append(name) }
        }
        return unknown
    }
}
