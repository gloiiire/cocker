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
        let rows: [UX.Table.Row] = store.contexts.map { ctx in
            .init([
                .init(ctx.name),
                .init(ctx.description.isEmpty ? "—" : ctx.description, color: ctx.description.isEmpty ? .dim : .default),
                .init(ctx.dockerHost, color: .dim),
                .init(ctx.name == store.current ? "*" : "", color: .success),
            ])
        }
        let table = UX.Table(
            columns: [
                .init("NAME"),
                .init("DESCRIPTION"),
                .init("DOCKER ENDPOINT"),
                .init("CURRENT"),
            ],
            rows: rows,
            emptyMessage: "no contexts — run `cocker context create <name>` to add one"
        )
        print(table.render())
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
            UX.Failure.emit(
                headline: "Cannot create context \(name)",
                reason: "a context with this name already exists",
                hint: "list existing ones with `cocker context ls`"
            )
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
        UX.printCreated(.context, name)
    }
}

struct ContextUseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use", abstract: "Set current context")

    @Argument
    var name: String

    mutating func run() async throws {
        var store = ContextStore.load()
        guard store.contexts.contains(where: { $0.name == name }) else {
            UX.Failure.emit(
                headline: "Cannot switch to context \(name)",
                reason: "context not found",
                hint: "list available contexts with `cocker context ls`"
            )
            throw ExitCode.failure
        }
        store.current = name
        try store.save()
        if UX.TTY.current.isInteractive {
            print(UX.ActionLine(
                icon: .success, type: .context, name: name,
                status: "Active", trailing: "current context updated"
            ).render())
        } else {
            print(name)
        }
    }
}

struct ContextRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a context")

    @Argument
    var names: [String]

    mutating func run() async throws {
        var store = ContextStore.load()
        var failed = false
        for name in names {
            guard name != "default" else {
                failed = true
                UX.Failure.emit(
                    headline: "Cannot remove context default",
                    reason: "the default context cannot be removed",
                    hint: "switch to it with `cocker context use default` if needed"
                )
                continue
            }
            store.contexts.removeAll { $0.name == name }
            if store.current == name { store.current = "default" }
            UX.printResult(.context, name, verb: .remove)
        }
        try store.save()
        if failed { throw ExitCode.failure }
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
