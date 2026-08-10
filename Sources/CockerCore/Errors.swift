import Foundation

public enum CockerError: Error, CustomStringConvertible {
    // Container errors
    case containerNotFound(String)
    case containerAlreadyExists(String)
    case containerNotRunning(String)
    case containerAlreadyRunning(String)

    // Image errors
    case imageNotFound(String)
    case imageAlreadyExists(String)
    case imagePullFailed(String, String)
    case invalidImageReference(String)
    case manifestNotFound(String)
    case layerDownloadFailed(String, String)

    // Build errors
    case dockerfileNotFound(String)
    case buildFailed(String)
    case invalidDockerfileInstruction(String)
    case buildContextTooLarge(UInt64)

    // Network errors
    case networkNotFound(String)
    case networkAlreadyExists(String)
    case networkInUse(String)
    case invalidSubnet(String)

    // Volume errors
    case volumeNotFound(String)
    case volumeAlreadyExists(String)
    case volumeInUse(String)

    // VM errors
    case vmStartFailed(String)
    case vmStopFailed(String)
    case kernelNotFound(String)
    case initrdNotFound(String)
    case vmCommunicationFailed(String)

    // IPC errors
    case daemonNotRunning
    case connectionFailed(String)
    case requestFailed(String)
    case responseDecodingFailed(String)
    /// A failure the daemon already described well. Carries the daemon's
    /// message VERBATIM — unlike `requestFailed`, its `description` adds no
    /// prefix, so the CLI doesn't stack "Request failed: Build failed: …".
    /// The transport throws this instead of re-wrapping daemon errors.
    /// A failure reported by cockerd. The `Int32?` is the daemon's own
    /// `exitCode` for that error, so the taxonomy survives the socket —
    /// without it every remote failure collapsed to a plain 1.
    case daemon(String, Int32? = nil)

    /// A `--restart` / compose `restart:` value we don't understand.
    /// Refused rather than silently downgraded to "never restart".
    case invalidRestartPolicy(String)
    /// A requested host port is already bound by something else.
    ///
    /// Payload is the `IP:port` we could not take. Raised before the VM boots
    /// so the run fails instead of producing a container whose published port
    /// exists only in `ps` — the forwarder used to lose this race silently,
    /// inside a detached child nobody waited on.
    case portAlreadyAllocated(String)
    /// An operation that only makes sense on a container that is not
    /// currently running. Payload is (container, what was attempted).
    ///
    /// `network connect`/`disconnect` re-key the L2 switch port, which is
    /// created when the VM boots and never re-keyed afterwards. They used to
    /// append to a JSON array and print success while the container stayed
    /// exactly where it was.
    case containerMustBeStopped(String, String)

    // Config errors
    case invalidPortMapping(String)
    case invalidVolumeSpec(String)
    case invalidEnvironmentVar(String)
    case invalidComposeFile(String)
    case invalidResourceName(kind: String, name: String, reason: String)

    // System errors
    case permissionDenied(String)
    case diskFull
    case unsupportedPlatform(String)
    /// A command cocker ships but does not implement. Reported instead of a
    /// fabricated success, so a script can tell the difference. The payload
    /// is the command name.
    case notImplemented(String)
    case internalError(String)
    /// state.json was written by a NEWER cockerd (schemaVersion > what this
    /// binary understands). Loading it would violate invariants we don't
    /// know about, so the daemon must refuse to start. Thrown from
    /// StateStore's loader ; main() surfaces it and exits — the store
    /// itself never calls exit() (library code must stay embeddable and
    /// testable).
    case stateSchemaTooNew(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .containerNotFound(let id): return "No such container: \(id)"
        case .containerAlreadyExists(let name): return "Container name already in use: \(name)"
        case .containerNotRunning(let id): return "Container is not running: \(id)"
        case .containerAlreadyRunning(let id): return "Container already running: \(id)"
        case .imageNotFound(let ref): return "No such image: \(ref)"
        case .imageAlreadyExists(let ref): return "Image already exists: \(ref)"
        case .imagePullFailed(let ref, let reason): return "Error pulling \(ref): \(reason)"
        case .invalidImageReference(let ref): return "Invalid image reference: \(ref)"
        case .manifestNotFound(let ref): return "Manifest not found: \(ref)"
        case .layerDownloadFailed(let digest, let reason): return "Failed to download layer \(digest): \(reason)"
        case .dockerfileNotFound(let path): return "Dockerfile not found at \(path)"
        case .buildFailed(let msg): return "Build failed: \(msg)"
        case .invalidDockerfileInstruction(let line): return "Invalid Dockerfile instruction: \(line)"
        case .buildContextTooLarge(let size): return "Build context too large: \(size / 1024 / 1024) MB"
        case .networkNotFound(let name): return "No such network: \(name)"
        case .networkAlreadyExists(let name): return "Network already exists: \(name)"
        case .networkInUse(let name): return "Network \(name) is in use"
        case .invalidSubnet(let s): return "Invalid subnet: \(s)"
        case .volumeNotFound(let name): return "No such volume: \(name)"
        case .volumeAlreadyExists(let name): return "Volume already exists: \(name)"
        case .volumeInUse(let name): return "Volume \(name) is in use"
        case .vmStartFailed(let msg): return "VM failed to start: \(msg)"
        case .vmStopFailed(let msg): return "VM failed to stop: \(msg)"
        case .kernelNotFound(let path): return "Linux kernel not found at \(path). Run: cockerd setup"
        case .initrdNotFound(let path): return "initrd not found at \(path). Run: cockerd setup"
        case .vmCommunicationFailed(let msg): return "VM communication error: \(msg)"
        case .daemonNotRunning: return "Cannot connect to cockerd. Start it with: cockerd"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .requestFailed(let msg): return "Request failed: \(msg)"
        case .responseDecodingFailed(let msg): return "Response decoding failed: \(msg)"
        case .daemon(let msg, _): return msg
        case .invalidRestartPolicy(let s): return "Invalid restart policy: \(s)"
        case .portAlreadyAllocated(let addr): return "Port \(addr) is already allocated"
        case .containerMustBeStopped(let id, let action):
            return "Cannot \(action) \(id) while it is running"
        case .invalidPortMapping(let s): return "Invalid port mapping: \(s) (expected format: host:container)"
        case .invalidVolumeSpec(let s): return "Invalid volume spec: \(s) (expected format: source:dest[:ro])"
        case .invalidEnvironmentVar(let s): return "Invalid environment variable: \(s)"
        case .invalidComposeFile(let msg): return "Invalid compose file: \(msg)"
        case .invalidResourceName(let kind, let name, let reason):
            return "Invalid \(kind) name '\(name)': \(reason)"
        case .permissionDenied(let op): return "Permission denied: \(op)"
        case .diskFull: return "No space left on device"
        case .unsupportedPlatform(let p): return "Unsupported platform: \(p)"
        case .notImplemented(let what):
            return "\(what) is not implemented — cocker targets a single Mac, "
                 + "not a cluster. Use `apple/container` or Docker Desktop if you need it." 
        case .internalError(let msg): return "Internal error: \(msg)"
        case .stateSchemaTooNew(let found, let supported):
            return "state.json schemaVersion=\(found) exceeds this cockerd's max (\(supported)). Upgrade cockerd or roll back the file."
        }
    }

    /// Charter §6 split into what / why / how, for `UX.Failure`. Most cases
    /// fall back to the flat `description` as the headline ; the ones where
    /// a reason or an actionable hint is knowable lift it out so the CLI can
    /// render the three-line block instead of one dense sentence.
    public var presentation: (headline: String, reason: String?, hint: String?) {
        switch self {
        case .daemonNotRunning:
            return ("Cannot connect to cockerd", "the daemon isn't running", "start it with `cockerd`")
        case .kernelNotFound:
            return ("Linux kernel not found", nil, "run `cockerd setup`")
        case .initrdNotFound:
            return ("initrd not found", nil, "run `cockerd setup`")
        case .buildFailed(let msg):
            return ("Build failed", msg, nil)
        case .imagePullFailed(let ref, let reason):
            return ("Failed to pull \(ref)", reason, nil)
        case .permissionDenied(let op):
            return ("Permission denied", op, nil)
        case .invalidRestartPolicy(let s):
            return ("Invalid restart policy: \(s)", nil,
                    "expected `no`, `always`, `unless-stopped`, `on-failure` "
                    + "or `on-failure:<max>`")
        case .portAlreadyAllocated(let addr):
            return ("Port \(addr) is already allocated",
                    "something else on this host is already listening there",
                    "stop it, or publish on a different host port")
        case .containerMustBeStopped(let id, let action):
            return ("Cannot \(action) \(id) while it is running",
                    "the network is wired when the VM boots and cannot be re-keyed live",
                    "stop the container, run the command, then start it again")
        case .invalidPortMapping(let s):
            return ("Invalid port mapping: \(s)", nil,
                    "expected `host:container`, optionally `IP:host:container` "
                    + "with a literal IPv4 address (e.g. `127.0.0.1:8080:80`)")
        case .invalidVolumeSpec(let s):
            return ("Invalid volume spec: \(s)", nil, "expected `source:dest[:ro]`")
        case .daemon(let msg, _):
            // The daemon already wrote a good message. Lift a leading
            // "Xxx failed: …" into headline + reason so it reads as a block
            // (e.g. "Build failed: RUN … exited 1" → what/why), otherwise
            // use it verbatim as the headline.
            if let sep = msg.range(of: ": "),
               msg[..<sep.lowerBound].lowercased().hasSuffix("failed") {
                return (String(msg[..<sep.lowerBound]),
                        String(msg[sep.upperBound...]), nil)
            }
            return (msg, nil, nil)
        default:
            return (description, nil, nil)
        }
    }

    /// Process exit code for this error. Binary 0/1 tells a script nothing ;
    /// this borrows Docker's 125–127 convention so `$?` distinguishes "no
    /// such object" from "daemon down" from "not runnable".
    public var exitCode: Int32 {
        switch self {
        case .containerNotFound, .imageNotFound, .networkNotFound, .volumeNotFound,
             .manifestNotFound, .dockerfileNotFound:
            return 127  // no such object
        case .permissionDenied, .notImplemented, .containerMustBeStopped:
            return 126  // found but not runnable
        case .daemon(_, let code):
            // The daemon told us what kind of failure this was ; keep it.
            // An older daemon sends nothing, so a plain failure it is.
            return code ?? 1
        case .daemonNotRunning, .connectionFailed, .responseDecodingFailed,
             .kernelNotFound, .initrdNotFound, .vmStartFailed, .vmStopFailed,
             .vmCommunicationFailed, .portAlreadyAllocated:
            return 125  // cocker itself failed
        default:
            return 1
        }
    }
}

extension CockerError: LocalizedError {
    public var errorDescription: String? { description }
}
