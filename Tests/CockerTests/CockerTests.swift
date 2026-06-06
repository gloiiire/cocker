import Testing
import Foundation
@testable import CockerCore

@Suite("Image Reference Parsing")
struct ImageReferenceTests {
    @Test func parseSimpleImage() throws {
        let ref = try ImageReference.parse("nginx")
        #expect(ref.repository == "library/nginx")
        #expect(ref.tag == "latest")
        #expect(ref.registry == "registry-1.docker.io")
    }

    @Test func parseTaggedImage() throws {
        let ref = try ImageReference.parse("nginx:1.25")
        #expect(ref.repository == "library/nginx")
        #expect(ref.tag == "1.25")
    }

    @Test func parseUserImage() throws {
        let ref = try ImageReference.parse("myuser/myapp:v2.0")
        #expect(ref.repository == "myuser/myapp")
        #expect(ref.tag == "v2.0")
        #expect(ref.registry == "registry-1.docker.io")
    }

    @Test func parsePrivateRegistry() throws {
        let ref = try ImageReference.parse("registry.example.com/myapp:latest")
        #expect(ref.registry == "registry.example.com")
        #expect(ref.repository == "myapp")
        #expect(ref.tag == "latest")
    }

    @Test func parseDigest() throws {
        let ref = try ImageReference.parse("nginx@sha256:abc123def456")
        #expect(ref.digest == "sha256:abc123def456")
    }
}

@Suite("Port Mapping Parsing")
struct PortMappingTests {
    @Test func parseSimplePort() throws {
        let p = try PortMapping.parse("8080:80")
        #expect(p.hostPort == 8080)
        #expect(p.containerPort == 80)
        #expect(p.proto == .tcp)
    }

    @Test func parseSinglePort() throws {
        let p = try PortMapping.parse("443")
        #expect(p.hostPort == 443)
        #expect(p.containerPort == 443)
    }

    @Test func parseInvalidPort() {
        #expect(throws: CockerError.self) {
            try PortMapping.parse("invalid")
        }
    }

    @Test func portDescription() throws {
        let p = try PortMapping.parse("8080:80")
        #expect(p.description == "0.0.0.0:8080->80/tcp")
    }
}

@Suite("Volume Mount Parsing")
struct VolumeMountTests {
    @Test func parseBindMount() throws {
        let v = try VolumeMount.parse("/host/path:/container/path")
        #expect(v.source == "/host/path")
        #expect(v.destination == "/container/path")
        #expect(!v.readOnly)
    }

    @Test func parseReadOnlyMount() throws {
        let v = try VolumeMount.parse("/host:/container:ro")
        #expect(v.readOnly)
    }

    @Test func parseNamedVolume() throws {
        let v = try VolumeMount.parse("myvolume:/data")
        #expect(v.source == "myvolume")
        #expect(v.destination == "/data")
    }
}

@Suite("Dockerfile Parser")
struct DockerfileParserTests {
    @Test func parseSimpleDockerfile() throws {
        let dockerfile = """
        FROM alpine:latest
        RUN apk add --no-cache curl
        COPY . /app
        WORKDIR /app
        CMD ["/app/main"]
        """
        let instructions = try parseDockerfile(dockerfile)
        #expect(instructions.count == 5)
        #expect(instructions[0].keyword == "FROM")
        #expect(instructions[0].args == "alpine:latest")
        #expect(instructions[4].keyword == "CMD")
    }

    @Test func skipComments() throws {
        let dockerfile = """
        # This is a comment
        FROM ubuntu:22.04
        # Another comment
        RUN apt-get update
        """
        let instructions = try parseDockerfile(dockerfile)
        #expect(instructions.count == 2)
    }

    @Test func handleLineContinuation() throws {
        let dockerfile = """
        FROM alpine:latest
        RUN apk add \\
            curl \\
            wget
        """
        let instructions = try parseDockerfile(dockerfile)
        #expect(instructions.count == 2)
        #expect(instructions[1].args.contains("curl"))
    }

    @Test func missingFromFails() {
        let dockerfile = "RUN echo hello"
        #expect(throws: CockerError.self) {
            try parseDockerfile(dockerfile)
        }
    }
}

@Suite("Container Model")
struct ContainerModelTests {
    @Test func containerCreation() {
        let c = Container(
            name: "test",
            image: "nginx:latest",
            command: ["/bin/nginx"]
        )
        #expect(c.status == .created)
        #expect(c.id.count == 12)
        #expect(c.name == "test")
    }

    @Test func containerSerialization() throws {
        let c = Container(name: "web", image: "nginx", command: [])
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(Container.self, from: data)
        #expect(decoded.id == c.id)
        #expect(decoded.name == c.name)
        #expect(decoded.image == c.image)
    }
}

@Suite("IPC Protocol")
struct IPCProtocolTests {
    @Test func requestEncoding() throws {
        let payload = RunRequest(config: RunConfig(image: "nginx"))
        let request = try IPCRequest(type: .run, payload: payload)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: data)
        #expect(decoded.type == .run)
    }

    @Test func responseDecoding() throws {
        let response = try IPCResponse(requestId: "test-id", payload: PingResponse())
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: data)
        #expect(decoded.success)
        #expect(decoded.requestId == "test-id")
        let ping = try decoded.decode(PingResponse.self)
        #expect(ping.version == CockerVersion.version)
    }

    @Test func errorResponse() throws {
        let response = IPCResponse(requestId: "err-id", error: "container not found")
        #expect(!response.success)
        #expect(response.error == "container not found")
    }
}
