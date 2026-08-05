import Foundation

// Protocol abstracting the userspace L2 switch so VMRuntime depends on the
// capability ("plug a VM into the switch fabric") rather than on the
// concrete implementation. Lets tests inject a fake that records calls
// without spinning up a real socketpair or learning table.

protocol L2Switching: Sendable {
    /// Register a new switch port for `containerID` with `staticMAC` already
    /// learned. Returns the VM-side FileHandle of a socketpair (the caller
    /// hands this to VZFileHandleNetworkDeviceAttachment).
    ///
    /// `network` is what the port is allowed to talk to. Frames are only
    /// delivered between ports on the same network — without it, every
    /// container on the host shares one flat segment no matter how many
    /// networks the user created.
    func addPort(containerID: String, staticMAC: String, network: String) async -> FileHandle?

    /// Tear down the port and remove its MAC from the learning table. Closes
    /// the switch-side fd so the read loop exits cleanly.
    func removePort(containerID: String) async
}

// Implementation lives in L2Switch.swift. The actor adopts the protocol
// via the extension declared there.
