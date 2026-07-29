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
        print(" " + UX.TTY.paint("→ Pulling", .progress) + " " + UX.TTY.paint(image, .accent) + " " + UX.TTY.paint("from registry", .dim))

        let client = IPCClient()
        let start = Date()
        let payload = PullRequest(reference: image, platform: platform)
        let request = try IPCRequest(type: .pull, payload: payload)

        // Layer state behind a reference type so the @Sendable streaming
        // closure can mutate it without tripping Swift 6's capture check
        // (a `var layerStates: [String: ...]` capture is rejected because
        // it outlives this function via the closure).
        final class LayerBuffer: @unchecked Sendable {
            var states: [String: LayerProgress] = [:]
        }
        let buf = LayerBuffer()
        let reporter = ProgressReporter()
        let fail = UX.FailFlag()

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
                    buf.states[id] = LayerProgress(status: status, current: current, total: total, detail: detail)
                    reporter.update(buf.states)
                }
            } else if event.stream == .error {
                fail.trip()
                UX.Failure.emit(headline: event.data)
            }
        }

        reporter.done()
        try fail.throwIfTripped()
        UX.printResult(.image, image, verb: .pull, elapsed: Date().timeIntervalSince(start))
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
        print(" " + UX.TTY.paint("→ Pushing", .progress) + " " + UX.TTY.paint(image, .accent))
        let client = IPCClient()
        let start = Date()
        let payload = PullRequest(reference: image)
        let request = try IPCRequest(type: .push, payload: payload)
        let fail = UX.FailFlag()
        try await client.sendStreaming(request) { event in
            switch event.stream {
            case .stdout: print(event.data, terminator: "")
            case .stderr: UX.writeStderr(event.data)
            case .status: print(UX.TTY.paint(event.data, .progress))
            case .error:  fail.trip(); UX.Failure.emit(headline: event.data)
            }
        }
        try fail.throwIfTripped()
        UX.printResult(.image, image, verb: .push, elapsed: Date().timeIntervalSince(start))
    }
}
