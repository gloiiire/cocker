import Foundation

// Bootstrap files that cockerd writes into a container's rootfs before
// booting the VM. These are read by cocker-init (PID 1) at boot :
//
//   /cocker-spec    — argv + env + workdir, NUL-separated (more robust
//                     than the kernel cmdline which can't carry spaces
//                     or quotes inside parameter values).
//   /etc/resolv.conf — points libc DNS at the in-VM proxy (127.0.0.1)
//                     which forwards over vsock to cockerd.
//   /etc/hosts      — minimal default + the container's own name/hostname.
//
// Extracted from VMRuntime so the file layout and content are unit-
// testable against a temp directory.

public enum RootfsBootstrap {

    // MARK: - /cocker-spec
    //
    // Wire format — length-prefixed binary, version 5. cocker-init's spec.c
    // accepts v2/v3/v4/v5 magic bytes and treats missing trailers as empty,
    // so older daemons writing v4 still boot under a v5-aware init binary.
    //
    //   magic:        "COCKER\x05" (7 bytes — "COCKER" + version byte 0x05)
    //   argc:         u32 BE
    //   for each argv : u32 BE length, then bytes
    //   envc:         u32 BE
    //   for each env entry : u32 BE length, then bytes
    //   wd_len:       u32 BE
    //   wd:           bytes
    //   user_len:     u32 BE
    //   user:         bytes   (empty → no setuid ; "name", "uid", or "uid:gid")
    //   privileged:   u8      (0/1)
    //   n_cap_add:    u32 BE
    //   for each cap_add : u32 BE cap number
    //   n_cap_drop:   u32 BE
    //   for each cap_drop : u32 BE cap number
    //   stop_signal:  u32 BE  (v5+ — POSIX signal number, e.g. 3 = SIGQUIT,
    //                  15 = SIGTERM. 0 = use init default SIGTERM.)
    //
    // All length fields are unsigned big-endian 32-bit. Strings are UTF-8.

    /// Magic header for the v5 spec format. cocker-init's spec_load() reads
    /// these 7 bytes first and refuses to proceed on mismatch.
    public static let specMagic: [UInt8] = Array("COCKER\u{05}".utf8)

    /// Resolve a Dockerfile `STOPSIGNAL` value (`"SIGQUIT"`, `"SIGTERM"`,
    /// `"3"`, …) into a POSIX signal number. Returns 0 ("use default") on
    /// nil / empty / unknown.
    public static func resolveStopSignal(_ raw: String?) -> UInt32 {
        guard let raw = raw?.uppercased().trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return 0 }
        if let n = UInt32(raw) { return n }
        // Strip optional "SIG" prefix.
        let key = raw.hasPrefix("SIG") ? String(raw.dropFirst(3)) : raw
        switch key {
        case "HUP":  return 1
        case "INT":  return 2
        case "QUIT": return 3
        case "ILL":  return 4
        case "TRAP": return 5
        case "ABRT": return 6
        case "BUS":  return 7
        case "FPE":  return 8
        case "KILL": return 9
        case "USR1": return 10
        case "SEGV": return 11
        case "USR2": return 12
        case "PIPE": return 13
        case "ALRM": return 14
        case "TERM": return 15
        case "STKFLT": return 16
        case "CHLD": return 17
        case "CONT": return 18
        case "STOP": return 19
        case "TSTP": return 20
        case "TTIN": return 21
        case "TTOU": return 22
        case "URG":  return 23
        case "XCPU": return 24
        case "XFSZ": return 25
        case "VTALRM": return 26
        case "PROF": return 27
        case "WINCH": return 28
        case "IO":   return 29
        case "PWR":  return 30
        case "SYS":  return 31
        default:     return 0
        }
    }

    /// Linux capability names → numbers, mirroring `<linux/capability.h>`.
    /// Used to encode `--cap-add` / `--cap-drop` lists in the spec ; the
    /// in-VM caps.c has the same table. Names accept the "CAP_" prefix
    /// optionally — matches Docker UX.
    public static let capNames: [String: Int32] = [
        "CHOWN": 0, "DAC_OVERRIDE": 1, "DAC_READ_SEARCH": 2,
        "FOWNER": 3, "FSETID": 4, "KILL": 5, "SETGID": 6, "SETUID": 7,
        "SETPCAP": 8, "LINUX_IMMUTABLE": 9, "NET_BIND_SERVICE": 10,
        "NET_BROADCAST": 11, "NET_ADMIN": 12, "NET_RAW": 13,
        "IPC_LOCK": 14, "IPC_OWNER": 15, "SYS_MODULE": 16, "SYS_RAWIO": 17,
        "SYS_CHROOT": 18, "SYS_PTRACE": 19, "SYS_PACCT": 20, "SYS_ADMIN": 21,
        "SYS_BOOT": 22, "SYS_NICE": 23, "SYS_RESOURCE": 24, "SYS_TIME": 25,
        "SYS_TTY_CONFIG": 26, "MKNOD": 27, "LEASE": 28, "AUDIT_WRITE": 29,
        "AUDIT_CONTROL": 30, "SETFCAP": 31, "MAC_OVERRIDE": 32,
        "MAC_ADMIN": 33, "SYSLOG": 34, "WAKE_ALARM": 35, "BLOCK_SUSPEND": 36,
        "AUDIT_READ": 37, "PERFMON": 38, "BPF": 39, "CHECKPOINT_RESTORE": 40,
    ]

    /// Resolve a single cap name (with or without "CAP_" prefix) to its
    /// kernel number. Returns nil on unknown.
    public static func resolveCap(_ name: String) -> Int32? {
        let n = name.uppercased()
        let key = n.hasPrefix("CAP_") ? String(n.dropFirst(4)) : n
        return capNames[key]
    }

    public static func encodeSpec(command: [String],
                                  env: [String: String],
                                  workdir: String?,
                                  user: String? = nil,
                                  privileged: Bool = false,
                                  capAdd: [String] = [],
                                  capDrop: [String] = [],
                                  stopSignal: String? = nil) -> Data {
        var data = Data()
        data.append(contentsOf: specMagic)

        // argv
        data.appendUInt32BE(UInt32(command.count))
        for arg in command {
            let bytes = Array(arg.utf8)
            data.appendUInt32BE(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }

        // env — inject sensible defaults if user didn't provide them
        var entries: [String] = []
        if env["PATH"] == nil {
            entries.append("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
        }
        if env["HOME"] == nil { entries.append("HOME=/root") }
        if env["TERM"] == nil { entries.append("TERM=xterm") }
        for (k, v) in env { entries.append("\(k)=\(v)") }

        data.appendUInt32BE(UInt32(entries.count))
        for entry in entries {
            let bytes = Array(entry.utf8)
            data.appendUInt32BE(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }

        // workdir
        let wd = workdir ?? env["WORKDIR"] ?? "/"
        let wdBytes = Array(wd.utf8)
        data.appendUInt32BE(UInt32(wdBytes.count))
        data.append(contentsOf: wdBytes)

        // user (v3+). Empty string ↔ no setuid (run as root, the default).
        let usr = user ?? ""
        let usrBytes = Array(usr.utf8)
        data.appendUInt32BE(UInt32(usrBytes.count))
        data.append(contentsOf: usrBytes)

        // caps (v4+). Privileged byte, then resolved cap_add / cap_drop
        // arrays. Unknown cap names are silently dropped — Docker logs a
        // warning but tolerates them.
        data.append(privileged ? 1 : 0)
        let addNums = capAdd.compactMap { resolveCap($0) }
        data.appendUInt32BE(UInt32(addNums.count))
        for n in addNums { data.appendUInt32BE(UInt32(bitPattern: n)) }
        let dropNums = capDrop.compactMap { resolveCap($0) }
        data.appendUInt32BE(UInt32(dropNums.count))
        for n in dropNums { data.appendUInt32BE(UInt32(bitPattern: n)) }

        // stop_signal (v5+). 0 = init's built-in default (SIGTERM).
        data.appendUInt32BE(resolveStopSignal(stopSignal))

        return data
    }

    /// Write the spec atomically into `<rootfs>/cocker-spec`.
    public static func writeSpec(to rootfsPath: URL,
                                 command: [String],
                                 env: [String: String],
                                 workdir: String?,
                                 user: String? = nil,
                                 privileged: Bool = false,
                                 capAdd: [String] = [],
                                 capDrop: [String] = [],
                                 stopSignal: String? = nil) throws {
        let data = encodeSpec(command: command, env: env, workdir: workdir,
                              user: user, privileged: privileged,
                              capAdd: capAdd, capDrop: capDrop,
                              stopSignal: stopSignal)
        try data.write(to: rootfsPath.appendingPathComponent("cocker-spec"), options: .atomic)
    }

    // MARK: - /etc/resolv.conf

    public static func buildResolvConf(dnsIP: String) -> String {
        """
        # Generated by cockerd
        nameserver \(dnsIP)
        nameserver ::1
        search cocker
        options ndots:1
        options timeout:1
        options attempts:2

        """
    }

    public static func writeResolvConf(to rootfsPath: URL, dnsIP: String) throws {
        let etcDir = rootfsPath.appendingPathComponent("etc")
        try? FileManager.default.createDirectory(at: etcDir, withIntermediateDirectories: true)
        let path = etcDir.appendingPathComponent("resolv.conf")
        try buildResolvConf(dnsIP: dnsIP).write(to: path, atomically: true, encoding: .utf8)
    }

    // MARK: - /etc/hosts

    public static func buildHosts(containerName: String, hostname: String, ip: String?) -> String {
        var hosts = """
        127.0.0.1   localhost
        ::1         localhost

        """
        if let ip {
            hosts += "\(ip)   \(containerName) \(hostname)\n"
        }
        return hosts
    }

    /// Writes /etc/hosts only if it doesn't already exist (to avoid clobbering
    /// the image's own hosts file with extra entries).
    public static func writeHostsIfAbsent(to rootfsPath: URL,
                                          containerName: String,
                                          hostname: String,
                                          ip: String?) throws {
        let etcDir = rootfsPath.appendingPathComponent("etc")
        try? FileManager.default.createDirectory(at: etcDir, withIntermediateDirectories: true)
        let path = etcDir.appendingPathComponent("hosts")
        if FileManager.default.fileExists(atPath: path.path) { return }
        try buildHosts(containerName: containerName, hostname: hostname, ip: ip)
            .write(to: path, atomically: true, encoding: .utf8)
    }
}

extension Data {
    fileprivate mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >>  8) & 0xFF))
        append(UInt8( value        & 0xFF))
    }
}

