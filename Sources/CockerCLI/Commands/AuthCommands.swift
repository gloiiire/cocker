import ArgumentParser
import CockerCore
import Foundation

struct LoginCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Log in to a container registry"
    )

    @Option(name: [.short, .customLong("username")], help: "Username")
    var username: String?

    @Option(name: [.short, .customLong("password")], help: "Password (use --password-stdin for security)")
    var password: String?

    @Flag(name: .customLong("password-stdin"), help: "Take password from stdin")
    var passwordStdin = false

    @Argument(help: "Registry hostname (default: registry-1.docker.io)")
    var server: String = "registry-1.docker.io"

    mutating func run() async throws {
        let user: String
        if let u = username {
            user = u
        } else {
            print("Username: ", terminator: "")
            fflush(stdout)
            guard let u = readLine()?.trimmingCharacters(in: .whitespaces), !u.isEmpty else {
                UX.Failure.emit(headline: "Login failed", reason: "username cannot be empty")
                throw ExitCode.failure
            }
            user = u
        }

        let pass: String
        if passwordStdin {
            guard let p = readLine()?.trimmingCharacters(in: .newlines), !p.isEmpty else {
                UX.Failure.emit(headline: "Login failed", reason: "password cannot be empty")
                throw ExitCode.failure
            }
            pass = p
        } else if let p = password {
            pass = p
        } else {
            // Read password without echo (using stty)
            print("Password: ", terminator: "")
            fflush(stdout)
            let stty = Process()
            stty.executableURL = URL(fileURLWithPath: "/bin/stty")
            stty.arguments = ["-echo"]
            try? stty.run(); stty.waitUntilExit()
            let p = readLine()?.trimmingCharacters(in: .newlines) ?? ""
            let sttyOn = Process()
            sttyOn.executableURL = URL(fileURLWithPath: "/bin/stty")
            sttyOn.arguments = ["echo"]
            try? sttyOn.run(); sttyOn.waitUntilExit()
            print("")
            guard !p.isEmpty else {
                UX.Failure.emit(headline: "Login failed", reason: "password cannot be empty")
                throw ExitCode.failure
            }
            pass = p
        }

        var store = CredentialStore.load()
        store.credentials[server] = CredentialStore.Credential(username: user, password: pass)
        try store.save()

        if UX.TTY.current.isInteractive {
            print(UX.ActionLine(
                icon: .success, name: server,
                status: "Logged in", trailing: "user " + UX.TTY.paint(user, .accent)
            ).render())
        } else {
            print(server)
        }
    }
}

struct LogoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Log out from a container registry"
    )

    @Argument(help: "Registry hostname (default: registry-1.docker.io)")
    var server: String = "registry-1.docker.io"

    mutating func run() async throws {
        var store = CredentialStore.load()
        if store.credentials.removeValue(forKey: server) != nil {
            try store.save()
            if UX.TTY.current.isInteractive {
                print(UX.ActionLine(
                    icon: .success, name: server, status: "Logged out"
                ).render())
            } else {
                print(server)
            }
        } else {
            UX.Warning.emit("Not logged in to \(server)", note: "no credentials to remove")
        }
    }
}
