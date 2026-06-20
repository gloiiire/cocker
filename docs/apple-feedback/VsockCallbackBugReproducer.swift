// VsockCallbackBugReproducer.swift
//
// Minimal-dependency Swift reproducer for the Virtualization.framework
// bug described in docs/APPLE-FEEDBACK-VSOCK-CALLBACK.md.
//
// Attach this file as-is to an Apple Feedback report. The goal is to make
// the bug observable in under 5 minutes of an Apple engineer's time.
//
// ──────────────────────────────────────────────────────────────────────
// USAGE (host side, macOS 14+ on Apple Silicon)
// ──────────────────────────────────────────────────────────────────────
//
// 1. Create a new Swift command-line tool in Xcode (File → New → Project →
//    macOS → Command Line Tool, Language: Swift). Replace main.swift with
//    this file.
//
// 2. In Signing & Capabilities, add the **Virtualization** entitlement
//    (com.apple.security.virtualization). Without it the framework refuses
//    to start a VM.
//
// 3. Provide a Linux kernel + initrd path via the two `let kernelPath` and
//    `let initrdPath` constants below. Any kernel that boots and runs an
//    in-VM init that listens on AF_VSOCK port 9000 is fine. The init
//    needs to do nothing more than accept(), write one 'A' byte, close().
//    (A 20-line C program — see GUEST SIDE below.)
//
// 4. Build & run from Xcode. The console should print:
//        probe 0: success (read 1 byte)
//        probe 1: success (read 1 byte)
//        probe 2: TIMEOUT — callback never fired
//        probe 3: TIMEOUT — callback never fired
//        … through probe 19, all TIMEOUT
//
// 5. To prove the fix would be "don't dispatch", flip USE_BACKGROUND_DISPATCH
//    to false. With it false (call from the main run loop directly) all 20
//    probes succeed.
//
// ──────────────────────────────────────────────────────────────────────
// GUEST SIDE (init that listens on vsock port 9000)
// ──────────────────────────────────────────────────────────────────────
//
// Build statically and use as your initrd's /init :
//
//   #include <sys/socket.h>
//   #include <linux/vm_sockets.h>
//   #include <unistd.h>
//
//   int main(void) {
//     int s = socket(AF_VSOCK, SOCK_STREAM, 0);
//     struct sockaddr_vm a = { .svm_family = AF_VSOCK,
//                              .svm_cid = VMADDR_CID_ANY,
//                              .svm_port = 9000 };
//     bind(s, (struct sockaddr*)&a, sizeof a);
//     listen(s, 16);
//     for (;;) {
//       int c = accept(s, 0, 0);
//       if (c < 0) continue;
//       write(c, "A", 1);
//       close(c);
//     }
//     return 0;
//   }
//
// Build with `zig cc -target aarch64-linux-musl -static -o init init.c`,
// pack into a single-file cpio initrd, point this reproducer at it.

import Foundation
import Virtualization

// ──────────────────────────────────────────────────────────────────────
// Configuration — fill these in with paths on your machine.
// ──────────────────────────────────────────────────────────────────────

let kernelPath = "/path/to/vmlinuz"             // Linux ARM64 kernel
let initrdPath = "/path/to/initrd.cpio"         // initrd shipping the C init above
let kernelCmdLine = "console=hvc0 quiet"
let probeCount = 20
let interProbeSleepSeconds: TimeInterval = 0.5
let perProbeTimeoutSeconds: TimeInterval = 3.0

/// Flip to `false` to demonstrate that calling `connect()` straight from
/// the main run loop (no background dispatch) does NOT hit the bug.
let USE_BACKGROUND_DISPATCH = true

// ──────────────────────────────────────────────────────────────────────

@MainActor
func boot() async throws -> VZVirtualMachine {
    let cfg = VZVirtualMachineConfiguration()
    cfg.cpuCount = 2
    cfg.memorySize = 1024 * 1024 * 1024  // 1 GiB

    let bootloader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: kernelPath))
    bootloader.initialRamdiskURL = URL(fileURLWithPath: initrdPath)
    bootloader.commandLine = kernelCmdLine
    cfg.bootLoader = bootloader

    // Required : the vsock device the reproducer connects through.
    cfg.socketDevices = [VZVirtioSocketDeviceConfiguration()]

    // Minimal console so kernel panics surface (otherwise the VM dies silent).
    let console = VZVirtioConsoleDeviceSerialPortConfiguration()
    console.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: FileHandle.standardInput,
        fileHandleForWriting: FileHandle.standardOutput
    )
    cfg.serialPorts = [console]

    try cfg.validate()

    let vm = VZVirtualMachine(configuration: cfg)
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        vm.start { result in
            switch result {
            case .success:        cont.resume()
            case .failure(let e): cont.resume(throwing: e)
            }
        }
    }
    return vm
}

/// One probe = one connect() + one read() + close(). Returns true on success.
@discardableResult
func probe(_ id: Int, device: VZVirtioSocketDevice) async -> Bool {
    let start = Date()
    return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
        let done = Atomic(false)
        // Hard deadline so a stuck handler doesn't lock the loop forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + perProbeTimeoutSeconds) {
            if done.swap(true) == false {
                print("probe \(id): TIMEOUT — callback never fired (\(perProbeTimeoutSeconds)s)")
                cont.resume(returning: false)
            }
        }

        let attempt: () -> Void = {
            device.connect(toPort: 9000) { result in
                if done.swap(true) == true { return }  // beat the timeout
                switch result {
                case .failure(let err):
                    print("probe \(id): connect failed: \(err)")
                    cont.resume(returning: false)
                case .success(let conn):
                    let fd = conn.fileDescriptor
                    var byte: UInt8 = 0
                    let n = read(fd, &byte, 1)
                    shutdown(fd, SHUT_RDWR)
                    let elapsed = String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
                    if n == 1 {
                        print("probe \(id): success (read 1 byte, \(elapsed))")
                        cont.resume(returning: true)
                    } else {
                        print("probe \(id): connected but read returned \(n)")
                        cont.resume(returning: false)
                    }
                }
            }
        }

        if USE_BACKGROUND_DISPATCH {
            DispatchQueue.global().async(execute: attempt)
        } else {
            attempt()
        }
    }
}

// Tiny atomic flag so the timeout & the handler don't both call resume().
final class Atomic<T> {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func swap(_ new: T) -> T {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = new
        return old
    }
}

@MainActor
func main() async {
    do {
        print("Booting VM…")
        let vm = try await boot()
        try await Task.sleep(nanoseconds: 2_000_000_000)  // let guest init bind the vsock port
        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            print("No VZVirtioSocketDevice on this VM — check the configuration.")
            return
        }
        print("Running \(probeCount) probes, USE_BACKGROUND_DISPATCH = \(USE_BACKGROUND_DISPATCH)")
        var successes = 0
        for i in 0..<probeCount {
            let ok = await probe(i, device: device)
            if ok { successes += 1 }
            try await Task.sleep(nanoseconds: UInt64(interProbeSleepSeconds * 1_000_000_000))
        }
        print("---")
        print("Result: \(successes)/\(probeCount) probes completed.")
        if USE_BACKGROUND_DISPATCH && successes < probeCount {
            print("This is the bug. Re-run with USE_BACKGROUND_DISPATCH = false")
            print("to confirm the same workload succeeds without the dispatch hop.")
        }
    } catch {
        print("Boot or probe failed: \(error)")
    }
    exit(0)
}

await main()
