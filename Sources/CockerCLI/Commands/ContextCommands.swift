import ArgumentParser
import CockerCore
import Foundation

struct ContextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Manage contexts (connections to daemon)",
        subcommands: [
            ContextLsCommand.self,
            ContextCreateCommand.self,
            ContextUseCommand.self,
            ContextRmCommand.self,
            ContextInspectCommand.self,
            ContextShowCommand.self,
        ]
    )
}

struct ContextLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List contexts")

    mutating func run() async throws {
        let store = ContextStore.load()
        let columns: [TableFormatter.Column] = [
            .init("NAME", min: 16),
            .init("DESCRIPTION", min: 24),
            .init("DOCKER ENDPOINT", min: 40),
            .init("CURRENT", min: 8),
        ]
        let rows = store.contexts.map { ctx -> [String] in
            [
                ctx.name,
                ctx.description,
                ctx.dockerHost,
                ctx.name == store.current ? ANSI.colored("*", ANSI.green) : "",
            ]
        }
        print(TableFormatter.format(columns: columns, rows: rows))
    }
}

struct ContextCreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a context")

    @Option(name: .customLong("description"))
    var description: String = ""

    @Option(name: .customLong("docker"), help: "Docker endpoint (e.g. host=unix:///path/to/socket)")
    var docker: String?

    @Argument
    var name: String

    mutating func run() async throws {
        var store = ContextStore.load()
        guard !store.contexts.contains(where: { $0.name == name }) else {
            fputs("Error: context \(name) already exists\n", stderr)
            throw ExitCode.failure
        }
        let host: String
        if let d = docker {
            // Parse "host=unix:///path" format
            let parts = d.split(separator: "=", maxSplits: 1)
            host = parts.count == 2 ? String(parts[1]) : d
        } else {
            host = "unix://\(NSHomeDirectory())/.cocker/cocker.sock"
        }
        let ctx = CockerContext(name: name, description: description, dockerHost: host)
        store.contexts.append(ctx)
        try store.save()
        print(name)
    }
}

struct ContextUseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use", abstract: "Set current context")

    @Argument
    var name: String

    mutating func run() async throws {
        var store = ContextStore.load()
        guard store.contexts.contains(where: { $0.name == name }) else {
            fputs("Error: context not found: \(name)\n", stderr)
            throw ExitCode.failure
        }
        store.current = name
        try store.save()
        print("Current context is now \"\(name)\"")
    }
}

struct ContextRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a context")

    @Argument
    var names: [String]

    mutating func run() async throws {
        var store = ContextStore.load()
        for name in names {
            guard name != "default" else {
                fputs("Error: cannot remove default context\n", stderr)
                continue
            }
            store.contexts.removeAll { $0.name == name }
            if store.current == name { store.current = "default" }
            print(name)
        }
        try store.save()
    }
}

struct ContextInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display context info")

    @Argument
    var names: [String] = []

    mutating func run() async throws {
        let store = ContextStore.load()
        let toShow: [CockerContext]
        if names.isEmpty {
            toShow = [store.currentContext].compactMap { $0 }
        } else {
            toShow = names.compactMap { n in store.contexts.first { $0.name == n } }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(data: try encoder.encode(toShow), encoding: .utf8) ?? "")
    }
}

struct ContextShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the current context")

    mutating func run() async throws {
        print(ContextStore.load().current)
    }
}
