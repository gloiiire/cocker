import ArgumentParser
import CockerCore
import Foundation

// MARK: - Plugin (stub)
//
// `cocker plugin` exists so docker-compose stacks that declare custom
// network / volume drivers via `docker plugin install <ref>` parse
// cleanly. Cocker doesn't execute plugin binaries — we record them in a
// JSON registry on disk so subsequent `ls` / `inspect` calls find them,
// but `enable` is a no-op and the plugin's logic is not actually loaded.
// A real plugin runtime would need an out-of-process executor and a
// stable ABI ; out of scope.

struct PluginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plugin",
        abstract: "Manage plugins",
        subcommands: [
            PluginInstallCommand.self,
            PluginLsCommand.self,
            PluginRmCommand.self,
            PluginEnableCommand.self,
            PluginDisableCommand.self,
            PluginInspectCommand.self,
        ]
    )
}

private struct PluginEntry: Codable {
    var name: String
    var enabled: Bool
    var installedAt: Date
}

private func pluginsFile() -> URL {
    let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cocker")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("plugins.json")
}

private func loadPlugins() -> [PluginEntry] {
    guard let data = try? Data(contentsOf: pluginsFile()),
          let list = try? JSONDecoder().decode([PluginEntry].self, from: data) else {
        return []
    }
    return list
}

private func savePlugins(_ plugins: [PluginEntry]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(plugins) {
        try? data.write(to: pluginsFile())
    }
}

struct PluginInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a plugin (stub — registered but not executed)")

    @Argument(help: "Plugin reference (e.g. vieux/sshfs)")
    var pluginRef: String

    @Flag(name: .customLong("disable"))
    var disable = false

    mutating func run() async throws {
        var plugins = loadPlugins()
        if plugins.contains(where: { $0.name == pluginRef }) {
            print("\(pluginRef) is already installed")
            return
        }
        plugins.append(PluginEntry(name: pluginRef, enabled: !disable, installedAt: Date()))
        savePlugins(plugins)
        print("Installed plugin \(pluginRef)")
        if !disable { print("Plugin enabled") }
    }
}

struct PluginLsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List plugins")

    mutating func run() async throws {
        let plugins = loadPlugins()
        print("ID            NAME                          DESCRIPTION                ENABLED")
        for p in plugins {
            let id = String(p.name.hash.magnitude, radix: 16).prefix(12)
            print("\(id)  \(p.name.padding(toLength: 30, withPad: " ", startingAt: 0))Cocker plugin              \(p.enabled ? "true" : "false")")
        }
    }
}

struct PluginRmCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove one or more plugins")

    @Argument(help: "Plugin name(s)")
    var names: [String]

    mutating func run() async throws {
        var plugins = loadPlugins()
        for name in names {
            plugins.removeAll { $0.name == name }
            print(name)
        }
        savePlugins(plugins)
    }
}

struct PluginEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "enable", abstract: "Enable a plugin")

    @Argument(help: "Plugin name")
    var name: String

    mutating func run() async throws {
        var plugins = loadPlugins()
        if let idx = plugins.firstIndex(where: { $0.name == name }) {
            plugins[idx].enabled = true
            savePlugins(plugins)
            print(name)
        } else {
            fputs("Error: no such plugin: \(name)\n", stderr)
            throw ExitCode.failure
        }
    }
}

struct PluginDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable a plugin")

    @Argument(help: "Plugin name")
    var name: String

    mutating func run() async throws {
        var plugins = loadPlugins()
        if let idx = plugins.firstIndex(where: { $0.name == name }) {
            plugins[idx].enabled = false
            savePlugins(plugins)
            print(name)
        } else {
            fputs("Error: no such plugin: \(name)\n", stderr)
            throw ExitCode.failure
        }
    }
}

struct PluginInspectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "inspect", abstract: "Display detailed information on a plugin")

    @Argument(help: "Plugin name")
    var names: [String]

    mutating func run() async throws {
        let plugins = loadPlugins()
        var entries: [[String: Any]] = []
        for name in names {
            guard let p = plugins.first(where: { $0.name == name }) else {
                fputs("Error: no such plugin: \(name)\n", stderr); continue
            }
            entries.append([
                "Name": p.name,
                "Enabled": p.enabled,
                "InstalledAt": ISO8601DateFormatter().string(from: p.installedAt),
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: entries, options: .prettyPrinted)
        print(String(data: data, encoding: .utf8) ?? "[]")
    }
}
