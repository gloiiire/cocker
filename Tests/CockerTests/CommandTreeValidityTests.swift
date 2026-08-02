import Testing
import Foundation
import ArgumentParser
@testable import CockerCLI

/// ArgumentParser validates a command's property wrappers the first time it
/// builds that command, and refuses the whole subtree if any are malformed.
///
/// `BuildxBuildCommand` declared `@Flag var load = true`. A boolean flag
/// defaulting to true can never be false, so ArgumentParser rejected it — and
/// because the check happens while building the tree, **every** `cocker
/// buildx` subcommand died with a validation dump before it ran. `ls`,
/// `create`, `use`, `rm`, `build`, `install-qemu`, even `buildx --help`.
///
/// The existing configuration tests only assert that names and flags are
/// *declared*, which is exactly what this bug satisfied. Walking the tree and
/// instantiating each command is what catches it.
@Suite("Command tree is constructible")
struct CommandTreeValidityTests {

    /// Every command reachable from the root, depth-first.
    private func allCommands(
        _ type: ParsableCommand.Type = CockerCLI.self,
        path: [String] = []
    ) -> [(path: [String], type: ParsableCommand.Type)] {
        let name = type.configuration.commandName ?? String(describing: type)
        let here = path + [name]
        var found: [(path: [String], type: ParsableCommand.Type)] = [(here, type)]
        for child in type.configuration.subcommands {
            found.append(contentsOf: allCommands(child, path: here))
        }
        return found
    }

    /// Instantiating a command is what runs ArgumentParser's property-wrapper
    /// validation. A malformed declaration throws here rather than at the
    /// user's terminal.
    @Test func everyCommandInstantiates() throws {
        var broken: [String] = []
        for (path, type) in allCommands() {
            do {
                _ = try type.parseAsRoot(["--help"])
            } catch let error as CleanExit {
                _ = error  // `--help` exits cleanly; that's a pass.
            } catch {
                // A ValidationError about flag *declaration* (as opposed to
                // user input) means this subtree is unusable.
                let text = "\(error)"
                if text.contains("Boolean flags") || text.contains("Validation failed") {
                    broken.append("\(path.joined(separator: " ")): \(text)")
                }
            }
        }
        #expect(broken.isEmpty, "malformed command declarations:\n\(broken.joined(separator: "\n"))")
    }

    /// The specific subtree that was broken, pinned so a regression is
    /// obvious rather than buried in the sweep above.
    @Test func buildxSubtreeIsUsable() throws {
        for argv in [["buildx"], ["buildx", "ls"], ["buildx", "build"], ["buildx", "install-qemu"]] {
            do {
                _ = try CockerCLI.parseAsRoot(argv + ["--help"])
            } catch is CleanExit {
                continue
            } catch {
                let text = "\(error)"
                #expect(!text.contains("Validation failed"),
                        "`cocker \(argv.joined(separator: " "))` is unbuildable: \(text)")
            }
        }
    }

    /// A `@Flag` that defaults to true is the exact shape ArgumentParser
    /// refuses. Nothing in the tree should reintroduce one.
    @Test func noBooleanFlagDefaultsToTrue() throws {
        var offenders: [String] = []
        for (path, type) in allCommands() {
            do {
                _ = try type.parseAsRoot([])
            } catch {
                if "\(error)".contains("Boolean flags") {
                    offenders.append(path.joined(separator: " "))
                }
            }
        }
        #expect(offenders.isEmpty, "commands with an always-true @Flag: \(offenders)")
    }
}
