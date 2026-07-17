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
    case daemon(String)

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
    case internalError(String)

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
        case .daemon(let msg): return msg
        case .invalidPortMapping(let s): return "Invalid port mapping: \(s) (expected format: host:container)"
        case .invalidVolumeSpec(let s): return "Invalid volume spec: \(s) (expected format: source:dest[:ro])"
        case .invalidEnvironmentVar(let s): return "Invalid environment variable: \(s)"
        case .invalidComposeFile(let msg): return "Invalid compose file: \(msg)"
        case .invalidResourceName(let kind, let name, let reason):
            return "Invalid \(kind) name '\(name)': \(reason)"
        case .permissionDenied(let op): return "Permission denied: \(op)"
        case .diskFull: return "No space left on device"
        case .unsupportedPlatform(let p): return "Unsupported platform: \(p)"
        case .internalError(let msg): return "Internal error: \(msg)"
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
        case .invalidPortMapping(let s):
            return ("Invalid port mapping: \(s)", nil, "expected `host:container`")
        case .invalidVolumeSpec(let s):
            return ("Invalid volume spec: \(s)", nil, "expected `source:dest[:ro]`")
        case .daemon(let msg):
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
        case .permissionDenied:
            return 126  // found but not runnable
        case .daemonNotRunning, .connectionFailed, .responseDecodingFailed,
             .kernelNotFound, .initrdNotFound, .vmStartFailed, .vmStopFailed,
             .vmCommunicationFailed:
            return 125  // cocker itself failed
        default:
            return 1
        }
    }
}

extension CockerError: LocalizedError {
    public var errorDescription: String? { description }
}
