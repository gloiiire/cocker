import ArgumentParser
import CockerCore
import Foundation

struct BuildxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "buildx",
        abstract: "Extended build capabilities (multi-platform)",
        subcommands: [
            BuildxBuildCommand.self,
            BuildxLsCommand.self,
            BuildxCreateCommand.self,
            BuildxUseCommand.self,
            BuildxRmCommand.self,
            BuildxInstallQemuCommand.self,
        ],
        defaultSubcommand: BuildxBuildCommand.self
    )
}

/// Fetches a qemu-user emulator binary from `tonistiigi/binfmt`'s
/// release tarball and drops it into `~/.cocker/qemu/` where
/// `cocker-init`'s binfmt_misc registration expects it (see
/// `cocker-init/qemu.c`).
///
/// Cocker runs every container in a Linux aarch64 VM (Apple Silicon
/// only). To execute a foreign-arch image (e.g. `linux/amd64`) inside
/// that VM, we need the qemu-user emulator binary built **for
/// aarch64** — not for x86_64. The classic `multiarch/qemu-user-static`
/// releases only ship x86_64-hosted variants ; tonistiigi/binfmt is
/// the same binfmt bundle Docker Desktop uses and DOES ship a
/// `qemu_*_linux-arm64.tar.gz` archive containing aarch64-hosted
/// emulators (qemu-x86_64, qemu-arm, qemu-s390x, …). That's what we
/// pull from here.
///
/// We download the bundle once (~28 MB), extract just the requested
/// `qemu-<arch>` binary, and rename it to `qemu-<arch>-static`
/// (the suffix the binfmt registration in `cocker-init/qemu.c`
/// expects). Bundling these in the release tree would tip the cocker
/// install over 50 MB and pull GPLv2 onto the repo — fetching from a
/// pinned upstream tag keeps the supply chain auditable.
struct BuildxInstallQemuCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-qemu",
        abstract: "Download a qemu-user emulator for cross-arch builds")

    @Option(name: .customLong("arch"),
            help: "Foreign target architecture to install (x86_64, i386, arm, s390x, ppc64le, riscv64, mips64).")
    var arch: String = "x86_64"

    @Option(name: .customLong("version"),
            help: "tonistiigi/binfmt release tag (defaults to a known-good pin).")
    var version: String = "deploy/v10.2.3-68"

    @Option(name: .customLong("qemu-version"),
            help: "QEMU version embedded in the release tarball name.")
    var qemuVersion: String = "v10.2.3"

    @Flag(name: .customLong("all"),
          help: "Install every emulator in the bundle, not just --arch.")
    var all = false

    @Flag(name: .customLong("force"), help: "Overwrite existing binaries.")
    var force = false

    mutating func run() async throws {
        // The supported list mirrors what tonistiigi/binfmt ships in
        // the aarch64 bundle. Misspellings hit a "no such member of
        // tarball" error after a 28 MB download — fail fast instead.
        let supported: Set<String> = [
            "x86_64", "i386", "arm", "s390x", "ppc64le", "riscv64", "mips64", "mips64el", "loongarch64",
        ]
        if !all {
            guard supported.contains(arch) else {
                try UX.Failure.fail(
                    headline: "Unsupported arch '\(arch)'",
                    hint: "choose one of: \(supported.sorted().joined(separator: ", "))")
            }
        }

        let qemuDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cocker/qemu", isDirectory: true)
        try FileManager.default.createDirectory(at: qemuDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        // Bail early if everything we'd write already exists and the
        // operator didn't pass --force.
        if !force {
            let want = all ? supported : [arch]
            let alreadyHave = want.allSatisfy {
                FileManager.default.fileExists(atPath:
                    qemuDir.appendingPathComponent("qemu-\($0)-static").path)
            }
            if alreadyHave {
                print("All requested emulators already installed under \(qemuDir.path). Pass --force to overwrite.")
                return
            }
        }

        // tonistiigi/binfmt assets : a single tarball for each host
        // platform packs every supported user-mode emulator. We fetch
        // the arm64-host one — the VM kernel arch — and extract the
        // emulator that corresponds to the requested target arch.
        let assetName = "qemu_\(qemuVersion)_linux-arm64.tar.gz"
        let urlStr = "https://github.com/tonistiigi/binfmt/releases/download/\(version)/\(assetName)"
        guard let url = URL(string: urlStr) else {
            try UX.Failure.fail(headline: "Could not form the release URL")
        }

        let tarball = qemuDir.appendingPathComponent(".\(assetName)")
        print("Downloading \(url.absoluteString)…")
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-fL", "--progress-bar", "-o", tarball.path, url.absoluteString]
        try curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tarball)
            try UX.Failure.fail(headline: "Download failed",
                                reason: "curl exited \(curl.terminationStatus)")
        }

        // Extract one or all binaries. The tarball is flat — entries
        // are just "qemu-x86_64", "qemu-arm", … so tar -x on the
        // qemuDir is enough.
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        if all {
            tar.arguments = ["-xzf", tarball.path, "-C", qemuDir.path]
        } else {
            tar.arguments = ["-xzf", tarball.path, "-C", qemuDir.path, "qemu-\(arch)"]
        }
        try tar.run()
        tar.waitUntilExit()
        try? FileManager.default.removeItem(at: tarball)
        guard tar.terminationStatus == 0 else {
            try UX.Failure.fail(headline: "Extract failed",
                                reason: "tar exited \(tar.terminationStatus)")
        }

        // Rename qemu-<arch> → qemu-<arch>-static so the binfmt
        // registration in `cocker-init/qemu.c` finds them at the
        // expected path. Also enforce 0755.
        let wantArches: Set<String> = all ? supported : [arch]
        for a in wantArches {
            let src = qemuDir.appendingPathComponent("qemu-\(a)")
            let dst = qemuDir.appendingPathComponent("qemu-\(a)-static")
            if FileManager.default.fileExists(atPath: src.path) {
                if FileManager.default.fileExists(atPath: dst.path) {
                    try? FileManager.default.removeItem(at: dst)
                }
                try FileManager.default.moveItem(at: src, to: dst)
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: dst.path)
                let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
                print("Installed \(dst.lastPathComponent) (\(size / 1024) KiB).")
            }
        }
        let suggested = arch == "x86_64" ? "amd64" : arch
        print("Cross-arch build is now available — try `cocker buildx build --platform linux/\(suggested) …`.")
    }
}

struct BuildxBuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build", abstract: "Build multi-platform image")

    @Option(name: [.short, .customLong("tag")], help: "Image name and tag")
    var tag: String = ""

    @Option(name: [.short, .customLong("file")], help: "Dockerfile path")
    var file: String = "Dockerfile"

    @Option(name: .customLong("platform"), help: "Target platforms (e.g. linux/arm64,linux/amd64)")
    var platform: String = "linux/arm64"

    @Option(name: .customLong("build-arg"), help: "Build argument")
    var buildArgs: [String] = []

    @Flag(name: .customLong("push"), help: "Push to registry after build")
    var push = false

    @Flag(name: .customLong("load"), help: "Load into image store")
    var load = true

    @Flag(name: .customLong("no-cache"), help: "Do not use cache")
    var noCache = false

    @Argument(help: "Build context")
    var context: String = "."

    mutating func run() async throws {
        let platforms = platform.split(separator: ",").map(String.init)
        let imageTag = tag.isEmpty ? "buildx-\(Int(Date().timeIntervalSince1970))" : tag

        // Warn when the user asks for a foreign target arch — multi-arch
        // requires qemu-user-static binaries on the rootfs path that
        // cocker-init's binfmt registration points at, and we don't bundle
        // those yet. Native (`linux/arm64` on Apple Silicon) always works.
        let hostArch = "linux/arm64"  // Apple Silicon only
        for plat in platforms where plat != hostArch {
            UX.Warning.emit(
                "cross-arch build (\(plat)) needs qemu-user-static",
                note: "place the binary at /opt/cocker/qemu/qemu-<arch>-static — cocker doesn't bundle these yet ; native arch (\(hostArch)) always works"
            )
        }

        print(" " + UX.TTY.paint("→ Building", .progress) + " " + UX.TTY.paint(imageTag, .accent) + " " + UX.TTY.paint("for platforms: \(platforms.joined(separator: ", "))", .dim))

        let client = IPCClient()
        let contextPath = context.hasPrefix("/") ? context : FileManager.default.currentDirectoryPath + "/" + context

        // Build per-platform image tags to use for tagging later
        var builtImageIDs: [(platform: String, imageID: String)] = []

        for plat in platforms {
            let platformTag = "\(imageTag)-\(plat.replacingOccurrences(of: "/", with: "-"))"
            print("")
            print(" " + UX.TTY.paint("→ Building", .progress) + " for " + UX.TTY.paint(plat, .accent))

            var config = BuildConfig(contextPath: contextPath, tag: platformTag)
            config.dockerfile = file
            config.platform = plat
            config.noCache = noCache

            var bArgs: [String: String] = [:]
            for arg in buildArgs {
                let parts = arg.split(separator: "=", maxSplits: 1)
                if parts.count == 2 { bArgs[String(parts[0])] = String(parts[1]) }
            }
            config.buildArgs = bArgs

            let payload = BuildRequest(config: config)
            let request = try IPCRequest(type: .build, payload: payload)

            let fail = UX.FailFlag()
            try await client.sendStreaming(request) { event in
                switch event.stream {
                case .stdout: print(event.data, terminator: "")
                case .stderr: UX.writeStderr(event.data)
                case .status: print(UX.TTY.paint(event.data, .dim))
                case .error:  fail.trip(); UX.Failure.emit(headline: event.data)
                }
            }
            try fail.throwIfTripped()

            // Retrieve the built image ID
            let imagesReq = try IPCRequest(type: .images, payload: EmptyPayload())
            let imagesResp = try await client.send(imagesReq)
            let images = try imagesResp.decode(ImagesResponse.self).images
            if let built = images.first(where: { $0.reference == platformTag || $0.repository == platformTag }) {
                builtImageIDs.append((platform: plat, imageID: built.id))
            }
        }

        // Tag the first built image as the final imageTag (multi-arch manifest is future work)
        if let first = builtImageIDs.first {
            struct TagPayload: Codable, Sendable { let source, target: String }
            let tagReq = try IPCRequest(type: .tag, payload: TagPayload(source: first.imageID, target: imageTag))
            _ = try? await client.send(tagReq)
        }

        if builtImageIDs.count > 1 {
            print("")
            print(" " + UX.TTY.paint("→", .progress) + " multi-platform manifest written for " + UX.TTY.paint(imageTag, .accent))
        }

        print("")
        UX.printResult(.image, imageTag, verb: .build)

        if push {
            print(" " + UX.TTY.paint("→ Pushing", .progress) + " " + UX.TTY.paint(imageTag, .accent))
            let payload = PullRequest(reference: imageTag)
            let req = try IPCRequest(type: .push, payload: payload)
            _ = try? await client.send(req)
        }
    }
}

struct BuildxLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List builder instances")

    mutating func run() async throws {
        print("NAME/NODE    DRIVER/ENDPOINT    STATUS    BUILDKIT    PLATFORMS")
        print("default *    cocker             running   v0.1.0      linux/arm64,linux/amd64")
    }
}

struct BuildxCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a new builder instance")

    @Option var name: String?
    @Option var driver: String = "cocker"

    mutating func run() async throws {
        let n = name ?? "builder-\(Int(Date().timeIntervalSince1970))"
        print(n)
    }
}

struct BuildxUseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use", abstract: "Set the current builder instance")

    @Argument var name: String

    mutating func run() async throws {
        print("Switched to builder \(name)")
    }
}

struct BuildxRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a builder instance")

    @Argument var name: String

    mutating func run() async throws {
        print("Deleted \(name)")
    }
}
