import ArgumentParser
import Foundation

/// `cocker completion <shell>` — emit the completion script for a
/// supported shell. Standard CLIs ship this so :
///   - `bash` users can `source` it (or drop it in
///     `/usr/local/etc/bash_completion.d/`).
///   - `zsh` users can put it in their `$fpath` (typically
///     `/usr/local/share/zsh/site-functions/_cocker`).
///   - `fish` users can drop it in
///     `~/.config/fish/completions/cocker.fish`.
///
/// Modern terminals (Warp, Zed's terminal, Kiro, iTerm with
/// suggestions, VS Code's terminal autocomplete) parse these
/// completion scripts to build their inline command pickers — that's
/// exactly the "`$ ps / inspect / volume / compose …` popup" the user
/// sees in Zed/Kiro. No special integration needed beyond shipping the
/// script ; the terminal does the rest.
///
/// ArgumentParser generates the scripts directly from our command
/// graph, so we don't have to hand-maintain anything — every new
/// subcommand or `@Option` is reflected the next time the user
/// re-sources the completion.
struct CompletionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completion",
        abstract: "Generate a shell completion script (bash/zsh/fish)",
        discussion: """
        Examples:

          # bash : append to your ~/.bashrc or ship system-wide
          cocker completion bash > /usr/local/etc/bash_completion.d/cocker

          # zsh : drop into your $fpath
          cocker completion zsh > /usr/local/share/zsh/site-functions/_cocker

          # fish
          cocker completion fish > ~/.config/fish/completions/cocker.fish

          # one-shot for the current shell session :
          source <(cocker completion zsh)
        """
    )

    @Argument(help: "Shell to target: bash, zsh, or fish")
    var shell: String

    mutating func run() async throws {
        let shellKind: CompletionShell
        switch shell.lowercased() {
        case "bash": shellKind = .bash
        case "zsh":  shellKind = .zsh
        case "fish": shellKind = .fish
        default:
            fputs("Unknown shell '\(shell)'. Supported: bash, zsh, fish.\n", stderr)
            throw ExitCode.failure
        }
        // ArgumentParser walks the root command's subcommand tree and
        // emits a complete script. Always picks up new commands and
        // flags so users only need to re-source after a `brew upgrade`.
        let script = CockerCLI.completionScript(for: shellKind)
        print(script)
    }
}
