import ArgumentParser
import CockerCore
import Foundation

@main
struct CockerCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cocker",
        abstract: "A Docker-compatible container engine powered by Apple Virtualization.framework",
        version: CockerVersion.version,
        subcommands: [
            // Auth
            LoginCommand.self,
            LogoutCommand.self,

            // Container lifecycle
            RunCommand.self,
            StartCommand.self,
            StopCommand.self,
            KillCommand.self,
            RestartCommand.self,
            PauseCommand.self,
            UnpauseCommand.self,
            RmCommand.self,
            RenameCommand.self,
            AttachCommand.self,
            ContainerPruneCommand.self,

            // Container info & interaction
            PSCommand.self,
            InspectCommand.self,
            LogsCommand.self,
            ExecCommand.self,
            CpCommand.self,
            TopCommand.self,
            StatsCommand.self,
            PortCommand.self,
            DiffCommand.self,

            // Image management
            PullCommand.self,
            PushCommand.self,
            BuildCommand.self,
            ImagesCommand.self,
            RmiCommand.self,
            TagCommand.self,
            ImageInspectCommand.self,
            SaveCommand.self,
            LoadCommand.self,
            CommitCommand.self,
            ExportCommand.self,
            ImportCommand.self,
            UpdateCommand.self,

            // Network
            NetworkCommand.self,

            // Volume
            VolumeCommand.self,

            // Compose
            ComposeCommand.self,

            // Buildx (multi-platform)
            BuildxCommand.self,

            // Context
            ContextCommand.self,

            // Swarm / Stack / Node / Service
            SwarmCommand.self,
            StackCommand.self,
            NodeCommand.self,
            ServiceCommand.self,

            // Daemon lifecycle (start/stop/restart/status/logs)
            DaemonCommand.self,

            // Secrets & configs
            SecretCommand.self,
            ConfigCommand.self,

            // Plugins (registration stubs)
            PluginCommand.self,

            // System
            VersionCommand.self,
            InfoCommand.self,
            PruneCommand.self,
        ],
        defaultSubcommand: nil
    )

    static func main() async {
        // Bare `cocker` (no args) used to surface as
        //   "Error: The operation couldn't be completed.
        //    (ArgumentParser.CleanExit error 1.)"
        // because the outer catch only got error.localizedDescription. Show
        // the help text instead — that's what users (and `docker` itself) expect.
        // Bare `cocker` and top-level `-h`/`--help` both get our beautified
        // warm-palette help screen instead of ArgumentParser's flat list.
        // Subcommand-level helps (e.g. `cocker run -h`) still go through
        // ArgumentParser since we don't override those.
        if CommandLine.arguments.count <= 1
            || (CommandLine.arguments.count == 2
                && (CommandLine.arguments[1] == "-h"
                 || CommandLine.arguments[1] == "--help")) {
            let colored = isatty(fileno(stdout)) == 1
            print(Banner.cockerCLIHelp(version: CockerVersion.version, colored: colored))
            return
        }

        // `-v` shorthand for `--version`. ArgumentParser auto-generates only
        // the long form when you set `version:` on the configuration, so we
        // intercept the common short alias here. Matches `docker -v`.
        if CommandLine.arguments.count == 2,
           CommandLine.arguments[1] == "-v" {
            print("Cocker version \(CockerVersion.version)")
            return
        }

        // One unified error funnel that handles every case ArgumentParser
        // can throw at us — including help requests bubbling out of `run()`
        // on commands like `cocker compose` that have subcommands but no
        // default. The previous code only caught CleanExit at parseAsRoot()
        // time, so calling a subcommand-less parent surfaced the ugly
        // localizedDescription :
        //   "The operation couldn't be completed. (ArgumentParser.CleanExit error 1.)"
        do {
            let cmd = try parseAsRoot()
            if var async = cmd as? AsyncParsableCommand {
                try await async.run()
            } else {
                var mutable = cmd
                try mutable.run()
            }
        } catch {
            let colored = isatty(fileno(stdout)) == 1
            let raw = Self.fullMessage(for: error)
            let code = Self.exitCode(for: error)

            // CockerError surfaces as a typed value — print it in red,
            // exit 1. (`fullMessage` would already include it, but we
            // want the consistent "Error:" prefix the rest of the codebase
            // uses for application-level failures.)
            if let cockerErr = error as? CockerError {
                fputs("\(ANSI.colored("Error:", ANSI.red)) \(cockerErr.description)\n", stderr)
                Foundation.exit(1)
            }

            // ExitCode propagated from inside run() — pass through.
            if let exitCode = error as? ExitCode {
                Foundation.exit(Int32(exitCode.rawValue))
            }

            // Everything else (CleanExit help requests, parse errors,
            // missing-subcommand errors). We colorize the help/error text
            // and route to the right stream based on the exit code.
            let painted = Banner.colorizeArgumentParserHelp(raw, colored: colored)
            if code == .success {
                print(painted)
                Foundation.exit(0)
            } else {
                FileHandle.standardError.write(Data((painted + "\n").utf8))
                Foundation.exit(Int32(code.rawValue))
            }
        }
    }
}
