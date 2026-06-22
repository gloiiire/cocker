import ArgumentParser
import Foundation

/// `cocker shell-completion <shell>` — emit the native TAB-completion
/// script for a supported shell :
///   - `bash` users can `source` it (or drop it in
///     `/usr/local/etc/bash_completion.d/`).
///   - `zsh` users can put it in their `$fpath` (typically
///     `/usr/local/share/zsh/site-functions/_cocker`).
///   - `fish` users can drop it in
///     `~/.config/fish/completions/cocker.fish`.
///
/// ArgumentParser generates the scripts directly from our command
/// graph, so we don't have to hand-maintain anything — every new
/// subcommand or `@Option` is reflected the next time the user
/// re-sources the completion.
///
/// **Naming note (v0.7.7)** : this command used to be `cocker
/// completion`. We renamed it to `shell-completion` to disambiguate
/// from `cocker autocomplete`, which installs the **Kiro/Fig spec**
/// (a totally different mechanism — popup with descriptions / icons /
/// dynamic generators, not a shell TAB script). The old name stays as
/// a hidden alias so existing scripts don't break overnight ;
/// documentation now exclusively references the new name.
struct CompletionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shell-completion",
        abstract: "Generate a native shell completion script (bash/zsh/fish)",
        discussion: """
        Examples:

          # bash : append to your ~/.bashrc or ship system-wide
          cocker shell-completion bash > /usr/local/etc/bash_completion.d/cocker

          # zsh : drop into your $fpath
          cocker shell-completion zsh > /usr/local/share/zsh/site-functions/_cocker

          # fish
          cocker shell-completion fish > ~/.config/fish/completions/cocker.fish

          # one-shot for the current shell session :
          source <(cocker shell-completion zsh)

        For the rich Kiro CLI / Fig popup (different system), see
        `cocker autocomplete install`.
        """,
        aliases: ["completion"]
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
            UX.Failure.emit(
                headline: "Unknown shell '\(shell)'",
                reason: "supported shells are bash, zsh, fish",
                hint: "for rich Kiro autocomplete, see `cocker autocomplete install`"
            )
            throw ExitCode.failure
        }
        // ArgumentParser walks the root command's subcommand tree and
        // emits a complete script. Always picks up new commands and
        // flags so users only need to re-source after a `brew upgrade`.
        let script = CockerCLI.completionScript(for: shellKind)
        print(script)
    }
}
