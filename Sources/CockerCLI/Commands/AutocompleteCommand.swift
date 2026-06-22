import ArgumentParser
import CockerCore
import Foundation

/// `cocker autocomplete` — manage rich-completion specs for Kiro CLI /
/// Fig from the user's shell, outside Homebrew's seatbelt sandbox.
///
/// Reason this exists : Homebrew runs `post_install` inside a sandbox
/// that denies writes to `~/.fig/`, so the formula can't drop the spec
/// at install time on macOS. Following the same pattern as
/// `cocker daemon setup` (which exists because the sandbox also blocks
/// `~/.cocker/kernel/` writes), we expose a small CLI command the user
/// runs once from their shell to finish the wiring.
struct AutocompleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "autocomplete",
        abstract: "Install / inspect rich autocomplete specs (Kiro CLI, Fig)",
        discussion: """
        cocker ships a Fig-format autocomplete spec under
        <homebrew-prefix>/share/cocker/completions/kiro/cocker.ts. Run
        `cocker autocomplete install` once after `brew install cocker`
        to copy it into ~/.fig/autocomplete/build/ where Kiro CLI's
        bundled autocomplete reads custom specs from.
        """,
        subcommands: [AutocompleteInstallCommand.self,
                      AutocompleteStatusCommand.self]
    )
}

struct AutocompleteInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Copy the Kiro/Fig autocomplete spec into ~/.fig/autocomplete/build/",
        discussion: """
        Looks for the spec at every standard Homebrew prefix (and falls
        back to a path relative to the running `cocker` binary so source
        installs work too), then copies it to
        ~/.fig/autocomplete/build/cocker.ts. Restart your terminal
        afterwards to pick up the change.

        Idempotent — re-running just overwrites the previous copy.
        """
    )

    @Option(name: .customLong("source"),
            help: "Explicit path to cocker.ts (skips auto-discovery)")
    var explicitSource: String?

    @Flag(name: .customLong("dry-run"),
          help: "Print what would happen without modifying anything")
    var dryRun = false

    mutating func run() async throws {
        let fm = FileManager.default

        // 1. Find the source file. Three discovery layers, first match wins :
        //    a) explicit --source override
        //    b) common Homebrew prefixes
        //    c) relative to the running cocker binary (handles source
        //       builds where the user invoked `swift build` then ran
        //       .build/release/cocker without `brew install`)
        let candidates: [String] = {
            if let s = explicitSource { return [s] }
            var paths: [String] = []
            for prefix in ["/opt/homebrew", "/usr/local"] {
                paths.append("\(prefix)/share/cocker/completions/kiro/cocker.ts")
            }
            // Sibling-to-executable fallback. CommandLine.arguments[0] is
            // the path the user invoked us with ; resolve symlinks so
            // .../bin/cocker → cellar prefix.
            let argv0 = CommandLine.arguments[0]
            let exe = URL(fileURLWithPath: argv0).resolvingSymlinksInPath()
            // .../<prefix>/bin/cocker → .../<prefix>/share/cocker/completions/kiro/cocker.ts
            let exePrefix = exe.deletingLastPathComponent().deletingLastPathComponent()
            paths.append(exePrefix.appendingPathComponent("share/cocker/completions/kiro/cocker.ts").path)
            return paths
        }()

        guard let src = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            UX.Failure.emit(
                headline: "Cannot find cocker.ts to install",
                reason: "checked : " + candidates.joined(separator: ", "),
                hint: "pass --source <path>, or re-install cocker via `brew install --force cocker`"
            )
            throw ExitCode.failure
        }

        // 2. Resolve destination. Kiro CLI reads custom specs from
        //    ~/.fig/autocomplete/build/ (legacy Fig path, kept by Kiro for
        //    compatibility — confirmed in the bundled autocomplete JS).
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let destDir = home.appendingPathComponent(".fig/autocomplete/build")
        let dest = destDir.appendingPathComponent("cocker.ts")

        if dryRun {
            print(" " + UX.TTY.paint("→ would copy", .progress) + " " + UX.TTY.paint(src, .accent))
            print("   " + UX.TTY.paint("to     :", .dim) + " " + dest.path)
            print("   " + UX.TTY.paint("(dry-run — no change made)", .dim))
            return
        }

        // 3. Make sure the destination dir exists. Bail with a helpful
        //    failure if mkdir somehow fails (rare — implies a permission
        //    issue or a file blocking the path).
        do {
            try fm.createDirectory(at: destDir,
                                   withIntermediateDirectories: true,
                                   attributes: nil)
        } catch {
            UX.Failure.emit(
                headline: "Cannot create \(destDir.path)",
                reason: error.localizedDescription,
                hint: "check permissions on ~/.fig — `ls -la ~/.fig` should show your user"
            )
            throw ExitCode.failure
        }

        // 4. Replace any existing file or symlink at destination so the
        //    copy is clean (FileManager.copyItem refuses to overwrite).
        //    Handle the "empty dir created by v0.7.4 bottle bug" edge case
        //    too — removeItem works on both files and directories.
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        do {
            try fm.copyItem(atPath: src, toPath: dest.path)
        } catch {
            UX.Failure.emit(
                headline: "Could not copy spec to \(dest.path)",
                reason: error.localizedDescription
            )
            throw ExitCode.failure
        }

        // 5. Announce success. The "restart terminal" hint is critical —
        //    Kiro reads the spec at shell-init time, not lazily.
        let bytes = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        let trailing = UX.formatBytes(Int64(bytes)) + " → " + dest.path
        print(UX.ActionLine(
            icon: .success, name: "cocker.ts",
            status: "Installed", trailing: trailing
        ).render())
        print("   " + UX.TTY.paint("next   :", .dim) + " restart your terminal completely (close all windows)")
        print("   " + UX.TTY.paint("test   :", .dim) + " type `cocker ` (with a space) — Kiro should show the popup")
    }
}

struct AutocompleteStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show where cocker's autocomplete spec is installed (if at all)"
    )

    mutating func run() async throws {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let dest = home.appendingPathComponent(".fig/autocomplete/build/cocker.ts")

        guard fm.fileExists(atPath: dest.path) else {
            print(UX.ActionLine(
                icon: .item, name: "cocker.ts", status: "Not installed"
            ).render())
            print("   " + UX.TTY.paint("install :", .dim) + " cocker autocomplete install")
            return
        }

        // Sanity check : the v0.7.4 bottle bug left an empty DIRECTORY at
        // the destination. Catch that edge case explicitly so the user
        // gets actionable feedback instead of a misleading green ✓.
        var isDir: ObjCBool = false
        fm.fileExists(atPath: dest.path, isDirectory: &isDir)
        if isDir.boolValue {
            UX.Failure.emit(
                headline: "cocker.ts is a directory (v0.7.4 bottle bug)",
                reason: "the path \(dest.path) is a directory, not a file",
                hint: "run `cocker autocomplete install` to overwrite with the real spec"
            )
            throw ExitCode.failure
        }

        let attrs = try fm.attributesOfItem(atPath: dest.path)
        let bytes = attrs[.size] as? Int ?? 0
        let mtime = (attrs[.modificationDate] as? Date).map { relativeTime(from: $0) } ?? "?"
        print(UX.ActionLine(
            icon: .success, name: "cocker.ts",
            status: "Installed", trailing: "\(UX.formatBytes(Int64(bytes))) · modified \(mtime)"
        ).render())
        print("   " + UX.TTY.paint("path :", .dim) + " " + dest.path)
    }
}
