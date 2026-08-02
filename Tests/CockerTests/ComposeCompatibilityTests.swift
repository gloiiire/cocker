import Foundation
import Testing
import CockerCore
import Yams
@testable import CockerDaemon

/// Compose files that mainstream tooling produces, and that cocker either
/// rejected outright or silently mangled.
///
/// The rejections were the worst class: an unmodelled shape didn't degrade,
/// it failed the YAML decode and took the *entire file* down with
/// `invalidComposeFile` — no indication of which key was at fault.
@Suite("Compose file compatibility")
struct ComposeCompatibilityTests {

    private func decode(_ yaml: String) throws -> ComposeFile {
        try YAMLDecoder().decode(ComposeFile.self, from: yaml)
    }

    // MARK: - build:

    /// `build: ./frontend` is the short form most compose files use. Only the
    /// mapping form was modelled, so this rejected the whole file.
    @Test func acceptsTheBuildShorthand() throws {
        let file = try decode("""
        services:
          web:
            build: ./frontend
        """)
        #expect(file.services["web"]?.build?.context == "./frontend")
    }

    @Test func stillAcceptsTheBuildMapping() throws {
        let file = try decode("""
        services:
          web:
            build:
              context: ./app
              dockerfile: Dockerfile.dev
              target: builder
        """)
        let build = try #require(file.services["web"]?.build)
        #expect(build.context == "./app")
        #expect(build.dockerfile == "Dockerfile.dev")
        #expect(build.target == "builder")
    }

    /// `args:` is a map or a `KEY=value` list, like `environment:`. Only the
    /// map decoded, so the list form rejected the file.
    @Test func acceptsBuildArgsInBothShapes() throws {
        let asMap = try decode("""
        services:
          web:
            build:
              context: .
              args:
                VERSION: "1.2"
                DEBUG: "1"
        """)
        #expect(asMap.services["web"]?.build?.args?.dictionary == ["VERSION": "1.2", "DEBUG": "1"])

        let asList = try decode("""
        services:
          web:
            build:
              context: .
              args:
                - VERSION=1.2
                - DEBUG=1
        """)
        #expect(asList.services["web"]?.build?.args?.dictionary == ["VERSION": "1.2", "DEBUG": "1"])
    }

    /// A bare `- KEY` in the list form means "inherit", and must not be
    /// dropped on the floor.
    @Test func bareBuildArgKeepsItsKey() throws {
        let file = try decode("""
        services:
          web:
            build:
              context: .
              args:
                - INHERITED
        """)
        #expect(file.services["web"]?.build?.args?.dictionary == ["INHERITED": ""])
    }

    // MARK: - ports:

    @Test func parsesTheCommonForms() throws {
        #expect(try PortMapping.parseSpec("8080:80") == [PortMapping(hostPort: 8080, containerPort: 80)])
        #expect(try PortMapping.parseSpec("3000") == [PortMapping(hostPort: 3000, containerPort: 3000)])
    }

    /// Each of these used to throw, and compose `compactMap`'d the throw away
    /// — the port was never published and nothing said so.
    @Test func parsesUDP() throws {
        let mapped = try PortMapping.parseSpec("53:53/udp")
        #expect(mapped == [PortMapping(hostPort: 53, containerPort: 53, proto: .udp)])
    }

    @Test func acceptsAndIgnoresAHostBindAddress() throws {
        // cocker's forwarder binds all interfaces; dropping the mapping over
        // an unsupported bind address would be worse than binding it wider.
        #expect(try PortMapping.parseSpec("127.0.0.1:8080:80")
                == [PortMapping(hostPort: 8080, containerPort: 80)])
    }

    @Test func expandsAPortRange() throws {
        let mapped = try PortMapping.parseSpec("8000-8002:9000-9002")
        #expect(mapped == [
            PortMapping(hostPort: 8000, containerPort: 9000),
            PortMapping(hostPort: 8001, containerPort: 9001),
            PortMapping(hostPort: 8002, containerPort: 9002),
        ])
    }

    @Test func expandsASingleSidedRange() throws {
        #expect(try PortMapping.parseSpec("7000-7001").count == 2)
    }

    @Test func rejectsMismatchedRangeWidths() {
        #expect(throws: CockerError.self) { try PortMapping.parseSpec("8000-8005:9000-9001") }
    }

    @Test func rejectsGenuineNonsense() {
        #expect(throws: CockerError.self) { try PortMapping.parseSpec("notaport") }
        #expect(throws: CockerError.self) { try PortMapping.parseSpec("80:90/sctp") }
        #expect(throws: CockerError.self) { try PortMapping.parseSpec("99999:80") }
        #expect(throws: CockerError.self) { try PortMapping.parseSpec("8010-8000:80-90") }
    }

    /// `parse` keeps its single-mapping contract for existing callers.
    @Test func singleParseStillReturnsTheFirstMapping() throws {
        #expect(try PortMapping.parse("8080:80") == PortMapping(hostPort: 8080, containerPort: 80))
    }

    // MARK: - command / entrypoint

    /// `command: "npm run dev"` is shell form in compose, exactly like
    /// Dockerfile CMD. It used to be passed as one argv element, so the guest
    /// tried to exec a file literally named "npm run dev".
    @Test func stringCommandIsShellWrapped() throws {
        let file = try decode("""
        services:
          web:
            image: node
            command: "npm run dev"
        """)
        let cmd = try #require(file.services["web"]?.command)
        // The model keeps the raw form; the wrapping happens in buildRunConfig.
        if case .string(let line) = cmd {
            #expect(line == "npm run dev")
        } else {
            Issue.record("expected the string form to be preserved as .string")
        }
    }

    @Test func arrayCommandIsExecForm() throws {
        let file = try decode("""
        services:
          web:
            image: node
            command: ["npm", "run", "dev"]
        """)
        #expect(file.services["web"]?.command?.array == ["npm", "run", "dev"])
    }

    /// `entrypoint:` had nowhere to land — RunConfig carried no such field —
    /// so overriding an image's ENTRYPOINT was impossible from compose or the
    /// Docker API.
    @Test func runConfigCarriesAnEntrypointOverride() {
        var config = RunConfig(image: "nginx")
        #expect(config.entrypoint == nil)
        config.entrypoint = ["/bin/sh", "-c"]
        #expect(config.entrypoint == ["/bin/sh", "-c"])
    }

    @Test func entrypointDecodesInBothShapes() throws {
        let file = try decode("""
        services:
          a:
            image: x
            entrypoint: /docker-entrypoint.sh
          b:
            image: x
            entrypoint: ["/bin/sh", "-c", "echo hi"]
        """)
        #expect(file.services["a"]?.entrypoint?.array == ["/docker-entrypoint.sh"])
        #expect(file.services["b"]?.entrypoint?.array == ["/bin/sh", "-c", "echo hi"])
    }
}
