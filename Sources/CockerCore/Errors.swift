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
}

extension CockerError: LocalizedError {
    public var errorDescription: String? { description }
}
