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

            // Network
            NetworkCommand.self,

            // Volume
            VolumeCommand.self,

            // Compose
            ComposeCommand.self,

            // System
            VersionCommand.self,
            InfoCommand.self,
            PruneCommand.self,
        ],
        defaultSubcommand: nil
    )

    static func main() async {
        do {
            var cmd = try parseAsRoot()
            if var async = cmd as? AsyncParsableCommand {
                do {
                    try await async.run()
                } catch let error as CockerError {
                    fputs("\(ANSI.colored("Error:", ANSI.red)) \(error.description)\n", stderr)
                    throw ExitCode.failure
                } catch let error as ExitCode {
                    throw error
                } catch {
                    fputs("\(ANSI.colored("Error:", ANSI.red)) \(error.localizedDescription)\n", stderr)
                    throw ExitCode.failure
                }
            } else {
                try cmd.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
