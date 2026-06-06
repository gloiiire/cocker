import ArgumentParser
import CockerCore
import Foundation

struct PullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Pull an image from a registry"
    )

    @Option(name: .customLong("platform"), help: "Platform (e.g. linux/arm64)")
    var platform: String?

    @Argument(help: "Image reference (name[:tag][@digest])")
    var image: String

    mutating func run() async throws {
        print("Pulling \(ANSI.colored(image, ANSI.cyan)) from registry...")

        let client = IPCClient()
        let payload = PullRequest(reference: image, platform: platform)
        let request = try IPCRequest(type: .pull, payload: payload)

        var layerStates: [String: LayerProgress] = [:]
        let reporter = ProgressReporter()

        try await client.sendStreaming(request) { event in
            if event.stream == .status {
                // Parse layer progress: "layerId|status|current|total"
                let parts = event.data.split(separator: "|")
                if parts.count >= 2 {
                    let id = String(parts[0])
                    let status = String(parts[1])
                    let current = parts.count > 2 ? Int64(parts[2]) ?? 0 : 0
                    let total = parts.count > 3 ? Int64(parts[3]) ?? 0 : 0
                    let detail = total > 0 ? "\(formatBytes(UInt64(current)))/\(formatBytes(UInt64(total)))" : ""
                    layerStates[id] = LayerProgress(status: status, current: current, total: total, detail: detail)
                    reporter.update(layerStates)
                }
            } else if event.stream == .error {
                fputs("\nError: \(event.data)\n", stderr)
            }
        }

        reporter.done()
        print("\nStatus: Image is up to date for \(ANSI.colored(image, ANSI.cyan))")
    }
}

struct PushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push an image to a registry"
    )

    @Argument(help: "Image reference")
    var image: String

    mutating func run() async throws {
        print("Pushing \(ANSI.colored(image, ANSI.cyan))...")
        let client = IPCClient()
        let payload = PullRequest(reference: image)
        let request = try IPCRequest(type: .push, payload: payload)
        _ = try await client.send(request)
        print("Successfully pushed \(image)")
    }
}
