import Foundation

// Pure builder for the Linux kernel boot command line that cockerd hands to
// VZLinuxBootLoader.commandLine. Extracted from VMRuntime so the cmdline
// construction is unit-testable without any VZ dependency.
//
// The result is a single space-separated string. Each cocker-specific
// parameter is namespaced under `cocker.*` so it doesn't collide with any
// stock kernel param. cocker-init (PID 1 in the guest) parses these from
// /proc/cmdline. See cocker-init/init.c.

public struct KernelCommandLineParams: Sendable {
    public let container: Container
    public let dnsIP: String
    public let dnsPort: UInt16
    public let dnsVsockPort: UInt32
    public let cockerSwitchGateway: String
    /// Foreign target arch (e.g. "x86_64") when this VM runs a
    /// cross-architecture build. nil for native arm64 → arm64. cocker-init
    /// reads this from the cmdline and registers a binfmt_misc handler
    /// so foreign-arch ELF binaries get transparently routed through
    /// qemu-user-static for emulation.
    public let qemuArch: String?
    /// In-VM path to the qemu-user-static binary (e.g.
    /// `/opt/cocker/qemu/qemu-x86_64-static`). cockerd mounts the host
    /// directory containing it as a virtiofs share named "qemu" at
    /// `/opt/cocker/qemu/`. nil when cross-arch isn't requested.
    public let qemuPath: String?
    /// Pre-resolved per-volume cmdline values, one per container.volumes
    /// entry in the same order. Format : `<type>:<src>:<target>` where
    /// type ∈ {"virtiofs", "blk"}. VMRuntime computes these because
    /// only it knows whether the source resolved to a directory (virtiofs)
    /// or a .img file (block device + which /dev/vd<X> letter). Empty
    /// array → cmdline emits no `cocker.vol*` params at all.
    public let volumeSpecs: [String]

    public init(container: Container,
                dnsIP: String,
                dnsPort: UInt16,
                dnsVsockPort: UInt32 = 5353,
                cockerSwitchGateway: String,
                qemuArch: String? = nil,
                qemuPath: String? = nil,
                volumeSpecs: [String] = []) {
        self.container = container
        self.dnsIP = dnsIP
        self.dnsPort = dnsPort
        self.dnsVsockPort = dnsVsockPort
        self.cockerSwitchGateway = cockerSwitchGateway
        self.qemuArch = qemuArch
        self.qemuPath = qemuPath
        self.volumeSpecs = volumeSpecs
    }
}

public enum KernelCommandLine {
    /// Build the full cmdline string for one container's VM boot.
    public static func build(_ params: KernelCommandLineParams) -> String {
        var parts = [
            "console=hvc0",
            "root=virtiofs",
            "rootfstype=virtiofs",
            "rw",
            "quiet",
            "cocker.id=\(params.container.id)",
            "cocker.name=\(params.container.name)",
            "cocker.dns=\(params.dnsIP)",
            "cocker.dns_port=\(params.dnsPort)",
            "cocker.dns_vsock_port=\(params.dnsVsockPort)",
        ]

        if !params.container.hostname.isEmpty {
            parts.append("cocker.hostname=\(params.container.hostname)")
        }

        // L2 switch (eth1) — inter-container fabric. cocker-init brings up
        // eth1 statically with this IP. Gateway is virtual (no host answers
        // ARP for it) but Linux needs one to consider the subnet usable.
        if let cIP = params.container.cockerIP, let cMAC = params.container.cockerMAC {
            parts.append("cocker.cnet_ip=\(cIP)/16")
            parts.append("cocker.cnet_gw=\(params.cockerSwitchGateway)")
            parts.append("cocker.cnet_mac=\(cMAC)")
        }

        // The container's command and env vars are written into /cocker-spec
        // (NUL-separated) because the kernel cmdline can't carry spaces or
        // quotes inside parameter values. See writeContainerSpec().

        // Port forward info — handled host-side by cocker-portfwd, but we
        // also pass it in so cocker-init can report on it.
        for port in params.container.ports {
            parts.append("cocker.port.\(port.containerPort)=\(port.hostPort)/\(port.proto.rawValue)")
        }

        // Per-volume cmdline. VMRuntime hands us the resolved spec
        // (already type-tagged with `virtiofs:` or `blk:`). If empty we
        // fall back to the legacy synthesis so non-VM call sites (tests,
        // tooling that pre-dates block storage) keep working.
        if !params.volumeSpecs.isEmpty {
            for (i, spec) in params.volumeSpecs.enumerated() {
                parts.append("cocker.vol\(i)=\(spec)")
            }
        } else {
            for (i, mount) in params.container.volumes.enumerated() {
                parts.append("cocker.vol\(i)=virtiofs:vol\(i):\(mount.destination)")
            }
        }

        if let workdir = params.container.env["WORKDIR"] {
            parts.append("cocker.workdir=\(workdir)")
        }

        if let user = params.container.env["USER"] {
            parts.append("cocker.user=\(user)")
        }

        // Cross-arch build : tell cocker-init what foreign-arch ELFs to
        // route through qemu-user-static. Without these two params the
        // qemu_register_binfmt path in qemu.c is a no-op.
        if let arch = params.qemuArch, let path = params.qemuPath {
            parts.append("cocker.qemu_arch=\(arch)")
            parts.append("cocker.qemu_path=\(path)")
        }

        return parts.joined(separator: " ")
    }
}
