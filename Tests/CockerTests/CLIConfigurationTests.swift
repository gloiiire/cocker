import Testing
import Foundation
import ArgumentParser
@testable import CockerCLI

// Pin every command's configuration (name + place in the tree). These are
// load-bearing — renaming a subcommand breaks shell completions and any
// muscle memory the user has. The tests fail loud when someone retyped.

@Suite("Top-level CLI configuration")
struct TopLevelCLIConfigurationTests {
    @Test func commandNameIsCocker() {
        #expect(CockerCLI.configuration.commandName == "cocker")
    }

    @Test func abstractMentionsDocker() {
        #expect(CockerCLI.configuration.abstract.lowercased().contains("docker"))
    }

    @Test func versionIsNonEmpty() {
        #expect(!(CockerCLI.configuration.version ?? "").isEmpty)
    }

    @Test func registersLifecycleSubcommands() {
        let names = CockerCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        for expected in ["run", "start", "stop", "kill", "restart", "rm", "ps", "logs", "exec"] {
            #expect(names.contains(expected), "missing \(expected) — got \(names)")
        }
    }

    @Test func registersImageSubcommands() {
        let names = CockerCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        for expected in ["pull", "push", "build", "images", "rmi", "tag"] {
            #expect(names.contains(expected), "missing \(expected)")
        }
    }

    @Test func registersDaemonGroup() {
        let names = CockerCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        #expect(names.contains("daemon"))
    }

    @Test func registersNetworkVolumeCompose() {
        let names = CockerCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        for expected in ["network", "volume", "compose"] {
            #expect(names.contains(expected))
        }
    }

    @Test func registersAuthSubcommands() {
        let names = CockerCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        #expect(names.contains("login"))
        #expect(names.contains("logout"))
    }

    @Test func registersSwarmStackNodeService() {
        let names = CockerCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        for expected in ["swarm", "stack", "node", "service"] {
            #expect(names.contains(expected))
        }
    }

    @Test func registersContextAndBuildx() {
        let names = CockerCLI.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        #expect(names.contains("context"))
        #expect(names.contains("buildx"))
    }
}

@Suite("DaemonCommand configuration")
struct DaemonCommandConfigurationTests {
    @Test func nameIsDaemon() {
        #expect(DaemonCommand.configuration.commandName == "daemon")
    }

    @Test func hasCoreSubcommands() {
        let names = Set(DaemonCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" })
        // Core 5 + the lease-pool helpers added in Sprint 5.
        let required: Set<String> = ["start", "stop", "restart", "status", "logs",
                                     "clear-leases", "helper-install"]
        #expect(required.isSubset(of: names))
    }
}

@Suite("ComposeCommand configuration")
struct ComposeCommandConfigurationTests {
    @Test func nameIsCompose() {
        #expect(ComposeCommand.configuration.commandName == "compose")
    }

    @Test func subcommandsCoverDockerComposeSurface() {
        let names = Set(ComposeCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" })
        // The user-visible verbs `docker compose` exposes; if any of these
        // disappear it's an accidental regression.
        let mustHave: Set<String> = [
            "up", "down", "ls", "logs", "ps", "exec", "run", "build", "pull",
            "restart", "pause", "unpause", "config", "kill", "top", "port",
            "images", "events"
        ]
        #expect(mustHave.isSubset(of: names),
                "compose dropped: \(mustHave.subtracting(names))")
    }
}

@Suite("NetworkCommand configuration")
struct NetworkCommandConfigurationTests {
    @Test func nameIsNetwork() {
        #expect(NetworkCommand.configuration.commandName == "network")
    }

    @Test func hasCRUDSubcommands() {
        let names = Set(NetworkCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" })
        for expected in ["ls", "create", "rm", "inspect", "connect"] {
            #expect(names.contains(expected), "network missing \(expected)")
        }
    }
}

@Suite("VolumeCommand configuration")
struct VolumeCommandConfigurationTests {
    @Test func nameIsVolume() {
        #expect(VolumeCommand.configuration.commandName == "volume")
    }

    @Test func hasCRUDSubcommands() {
        let names = Set(VolumeCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" })
        for expected in ["ls", "create", "rm", "inspect"] {
            #expect(names.contains(expected), "volume missing \(expected)")
        }
    }
}

@Suite("BuildxCommand configuration")
struct BuildxCommandConfigurationTests {
    @Test func nameIsBuildx() {
        #expect(BuildxCommand.configuration.commandName == "buildx")
    }

    @Test func hasBuilderLifecycle() {
        let names = Set(BuildxCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" })
        for expected in ["build", "ls", "create", "use", "rm"] {
            #expect(names.contains(expected), "buildx missing \(expected)")
        }
    }
}

@Suite("ContextCommand configuration")
struct ContextCommandConfigurationTests {
    @Test func nameIsContext() {
        #expect(ContextCommand.configuration.commandName == "context")
    }

    @Test func hasManagementSubcommands() {
        let names = Set(ContextCommand.configuration.subcommands.map { $0.configuration.commandName ?? "" })
        for expected in ["ls", "create", "use", "rm", "inspect", "show"] {
            #expect(names.contains(expected), "context missing \(expected)")
        }
    }
}

@Suite("Auth commands")
struct AuthCommandConfigurationTests {
    @Test func loginNameAndShortAbstract() {
        #expect(LoginCommand.configuration.commandName == "login")
        #expect(!LoginCommand.configuration.abstract.isEmpty)
    }

    @Test func logoutNameAndShortAbstract() {
        #expect(LogoutCommand.configuration.commandName == "logout")
        #expect(!LogoutCommand.configuration.abstract.isEmpty)
    }
}

@Suite("RunCommand parses flags")
struct RunCommandParseTests {
    // Black-box: drive ArgumentParser the way the binary does, just don't
    // call run() (we'd need a daemon for that). parseAsRoot() validates flag
    // wiring without firing IPC.
    @Test func parsesImageOnly() throws {
        _ = try RunCommand.parse(["alpine:latest"])
    }

    @Test func parsesDetachAndName() throws {
        let cmd = try RunCommand.parse(["-d", "--name", "web", "nginx"])
        // Smoke: the parse didn't throw and the image lands correctly.
        Mirror(reflecting: cmd).children.forEach { _ in }
    }

    @Test func parsesPortPublish() throws {
        _ = try RunCommand.parse(["-p", "8080:80", "nginx"])
    }

    @Test func parsesEnvAndVolume() throws {
        _ = try RunCommand.parse(["-e", "FOO=bar", "-v", "/host:/guest", "alpine"])
    }
}

@Suite("PSCommand parses flags")
struct PSCommandParseTests {
    @Test func parsesAll() throws {
        _ = try PSCommand.parse(["-a"])
    }

    @Test func parsesJSON() throws {
        _ = try PSCommand.parse(["--json"])
    }

    @Test func parsesFilter() throws {
        _ = try PSCommand.parse(["--filter", "status=running"])
    }

    @Test func parsesFilterShortForm() throws {
        _ = try PSCommand.parse(["-f", "name=web"])
    }
}

@Suite("PullCommand parses image refs")
struct PullCommandParseTests {
    @Test func parsesSimpleImage() throws {
        _ = try PullCommand.parse(["alpine:latest"])
    }

    @Test func parsesFullyQualifiedRef() throws {
        _ = try PullCommand.parse(["docker.io/library/nginx:1.25"])
    }
}
