import Foundation
import Darwin

/// Builds an AF_UNIX address without silently truncating the filesystem path.
/// Silent truncation is dangerous for servers because bind(2) can create a
/// different socket than the path subsequently chmod(2)'d.
public func makeUnixSocketAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !bytes.contains(0), bytes.count < capacity else {
        throw CockerError.internalError(
            "Unix socket path is too long (maximum \(capacity - 1) UTF-8 bytes): \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.copyBytes(from: bytes)
    }
    return address
}
