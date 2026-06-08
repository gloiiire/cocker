import Testing
import Foundation
@testable import CockerCore
@testable import CockerDaemon

// JSON codability of the Docker Engine API types. Both encoding (Encodable —
// what cockerd sends back) and decoding (Decodable — what cockerd accepts
// from clients).

@Suite("DockerVersion encodes")
struct DockerVersionTests {
    @Test func roundsTripIntoValidJSON() throws {
        let v = DockerVersion(KernelVersion: "6.12")
        let data = try JSONEncoder().encode(v)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["KernelVersion"] as? String == "6.12")
        // ApiVersion has a default; make sure it survives encode.
        #expect((dict?["ApiVersion"] as? String) == "1.47")
        #expect(dict?["Os"] as? String == "linux")
    }
}

@Suite("DockerInfo encodes")
struct DockerInfoTests {
    @Test func includesCockerMetadata() throws {
        let info = DockerInfo(
            ID: "cocker",
            Containers: 5, ContainersRunning: 2, ContainersPaused: 0, ContainersStopped: 3,
            Images: 12,
            DockerRootDir: "/tmp/.cocker",
            Name: "cocker-host",
            NCPU: 8, MemTotal: 1_000_000,
            Warnings: [], SecurityOptions: []
        )
        let data = try JSONEncoder().encode(info)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["NCPU"] as? Int == 8)
        #expect(dict?["Name"] as? String == "cocker-host")
        #expect(dict?["Containers"] as? Int == 5)
        #expect(dict?["Driver"] as? String == "virtiofs")
        #expect(dict?["OSType"] as? String == "linux")
        #expect(dict?["Architecture"] as? String == "aarch64")
    }
}

@Suite("DockerPort encodes")
struct DockerPortTests {
    @Test func tcpDefault() throws {
        let p = DockerPort(IP: "0.0.0.0", PrivatePort: 80, PublicPort: 8080, portType: "tcp")
        let data = try JSONEncoder().encode(p)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["PrivatePort"] as? Int == 80)
        #expect(dict?["PublicPort"] as? Int == 8080)
        // CodingKey rewrites portType -> "Type" in JSON.
        #expect(dict?["Type"] as? String == "tcp")
        #expect(dict?["portType"] == nil)
    }

    @Test func nilPublicPortStillEncodes() throws {
        let p = DockerPort(IP: nil, PrivatePort: 53, PublicPort: nil, portType: "udp")
        let data = try JSONEncoder().encode(p)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"PrivatePort\":53"))
    }
}

@Suite("DockerContainerSummary encodes")
struct DockerContainerSummaryTests {
    @Test func encodesAllRequiredFields() throws {
        let c = DockerContainerSummary(
            Id: "abc", Names: ["/web"], Image: "nginx", ImageID: "sha256:x",
            Command: "nginx -g daemon off;", Created: 1_700_000_000,
            Ports: [], Labels: ["app": "web"], State: "running",
            Status: "Up 1 minute",
            HostConfig: DockerContainerSummary.HostConfigSummary(NetworkMode: "bridge"),
            NetworkSettings: DockerContainerSummary.NetworkSettingsSummary(Networks: [:]),
            Mounts: []
        )
        let data = try JSONEncoder().encode(c)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["Id"] as? String == "abc")
        #expect((dict?["Names"] as? [String]) == ["/web"])
        #expect(dict?["State"] as? String == "running")
        #expect(dict?["Image"] as? String == "nginx")
    }
}

@Suite("DockerContainerCreateRequest decodes")
struct DockerContainerCreateRequestTests {
    @Test func minimalImageOnly() throws {
        let raw = #"{"Image":"alpine:latest"}"#
        let req = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Image == "alpine:latest")
        #expect(req.Cmd == nil)
        #expect(req.Env == nil)
    }

    @Test func withCmdEnvLabels() throws {
        let raw = #"""
        {
            "Image": "alpine:latest",
            "Cmd": ["echo", "hi"],
            "Env": ["FOO=bar", "BAZ=qux"],
            "Labels": {"env": "test"},
            "WorkingDir": "/app",
            "Hostname": "host"
        }
        """#
        let req = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Image == "alpine:latest")
        #expect(req.Cmd?.array == ["echo", "hi"])
        #expect(req.Env == ["FOO=bar", "BAZ=qux"])
        #expect(req.Labels?["env"] == "test")
        #expect(req.WorkingDir == "/app")
        #expect(req.Hostname == "host")
    }

    @Test func cmdAsStringExpandsViaShell() throws {
        let raw = #"{"Image":"alpine","Cmd":"echo hi"}"#
        let req = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(raw.utf8))
        // SingleOrArray wraps a bare string as `/bin/sh -c ...`.
        #expect(req.Cmd?.array == ["/bin/sh", "-c", "echo hi"])
    }

    @Test func entrypointAsArray() throws {
        let raw = #"{"Image":"alpine","Entrypoint":["/bin/init"]}"#
        let req = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Entrypoint?.array == ["/bin/init"])
    }

    @Test func tolerantToExtraFields() throws {
        // Docker requests carry many optional fields; the daemon must ignore
        // unknown keys silently. JSONDecoder does that by default.
        let raw = #"{"Image":"alpine","SomeFutureFieldDockerAdds":42}"#
        let req = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Image == "alpine")
    }

    @Test func failsWithoutImage() {
        let raw = #"{"Cmd":["echo","hi"]}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(raw.utf8))
        }
    }

    @Test func hostConfigPortBindings() throws {
        let raw = #"""
        {
            "Image": "alpine",
            "HostConfig": {
                "PortBindings": {
                    "80/tcp": [{"HostIp":"0.0.0.0","HostPort":"8080"}]
                }
            }
        }
        """#
        let req = try JSONDecoder().decode(DockerContainerCreateRequest.self, from: Data(raw.utf8))
        let binding = req.HostConfig?.PortBindings?["80/tcp"]?.first
        #expect(binding?.HostPort == "8080")
        #expect(binding?.HostIp == "0.0.0.0")
    }
}

@Suite("DockerContainerCreateResponse")
struct DockerContainerCreateResponseTests {
    @Test func includesIDAndWarnings() throws {
        let r = DockerContainerCreateResponse(Id: "abc123", Warnings: ["x"])
        let data = try JSONEncoder().encode(r)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["Id"] as? String == "abc123")
        #expect((dict?["Warnings"] as? [String]) == ["x"])
    }

    @Test func warningsCanBeEmpty() throws {
        let r = DockerContainerCreateResponse(Id: "abc", Warnings: [])
        let data = try JSONEncoder().encode(r)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"Warnings\":[]"))
    }
}

@Suite("DockerEmpty + DockerPullStatus")
struct DockerEmptyAndPullStatusTests {
    @Test func emptyEncodesAsEmptyObject() throws {
        let data = try JSONEncoder().encode(DockerEmpty())
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw == "{}")
    }

    @Test func pullStatusHasStatus() throws {
        let p = DockerPullStatus(
            status: "Downloading",
            progressDetail: DockerProgressDetail(current: 100, total: 1000),
            id: "abc",
            progress: "[==>]"
        )
        let data = try JSONEncoder().encode(p)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["status"] as? String == "Downloading")
        #expect(dict?["id"] as? String == "abc")
        #expect(dict?["progress"] as? String == "[==>]")
    }
}

@Suite("DockerImageSummary")
struct DockerImageSummaryTests {
    @Test func sensibleDefaults() throws {
        let img = DockerImageSummary(
            Id: "sha256:abc", ParentId: "", RepoTags: ["alpine:latest"],
            RepoDigests: [], Created: 1_700_000_000, Size: 5_000_000,
            SharedSize: -1, VirtualSize: 5_000_000, Labels: [:], Containers: 0
        )
        let data = try JSONEncoder().encode(img)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((dict?["RepoTags"] as? [String]) == ["alpine:latest"])
        #expect(dict?["Size"] as? Int == 5_000_000)
        #expect(dict?["SharedSize"] as? Int == -1)
    }
}

@Suite("DockerNetworkResource encodes")
struct DockerNetworkResourceTests {
    @Test func bridgeNetwork() throws {
        let ipam = DockerNetworkResource.DockerIPAM(
            Driver: "default",
            Config: [.init(Subnet: "10.42.0.0/16", Gateway: "10.42.0.1")],
            Options: [:]
        )
        let n = DockerNetworkResource(
            Name: "bridge", Id: "abc", Created: "2026-06-07",
            Scope: "local", Driver: "bridge", EnableIPv6: false,
            IPAM: ipam,
            Internal: false, Attachable: false, Ingress: false,
            Containers: [:], Options: [:], Labels: [:]
        )
        let data = try JSONEncoder().encode(n)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["Name"] as? String == "bridge")
        #expect(dict?["Driver"] as? String == "bridge")
        let ipamDict = dict?["IPAM"] as? [String: Any]
        let configs = ipamDict?["Config"] as? [[String: Any]]
        #expect(configs?.first?["Subnet"] as? String == "10.42.0.0/16")
    }
}

@Suite("DockerNetworkCreateRequest decodes")
struct DockerNetworkCreateRequestTests {
    @Test func nameOnly() throws {
        let raw = #"{"Name":"my-net"}"#
        let req = try JSONDecoder().decode(DockerNetworkCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Name == "my-net")
        #expect(req.Driver == nil)
    }

    @Test func withDriverAndIPAM() throws {
        let raw = #"""
        {
            "Name":"app",
            "Driver":"bridge",
            "IPAM":{"Config":[{"Subnet":"10.1.0.0/16","Gateway":"10.1.0.1"}]}
        }
        """#
        let req = try JSONDecoder().decode(DockerNetworkCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Name == "app")
        #expect(req.Driver == "bridge")
        #expect(req.IPAM?.Config?.first?.Subnet == "10.1.0.0/16")
    }
}

@Suite("DockerVolume types")
struct DockerVolumeTypesTests {
    @Test func volumeResourceEncodes() throws {
        let v = DockerVolumeResource(
            CreatedAt: "2026-06-07", Driver: "local", Labels: [:],
            Mountpoint: "/var/lib/cocker/volumes/foo",
            Name: "foo", Options: [:], Scope: "local"
        )
        let data = try JSONEncoder().encode(v)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["Name"] as? String == "foo")
        #expect(dict?["Driver"] as? String == "local")
    }

    @Test func volumeListResponseShape() throws {
        let list = DockerVolumeListResponse(Volumes: [], Warnings: [])
        let data = try JSONEncoder().encode(list)
        let raw = String(data: data, encoding: .utf8) ?? ""
        #expect(raw.contains("\"Volumes\":[]"))
        #expect(raw.contains("\"Warnings\":[]"))
    }

    @Test func volumeCreateRequestAllOptional() throws {
        let req = try JSONDecoder().decode(DockerVolumeCreateRequest.self, from: Data("{}".utf8))
        #expect(req.Name == nil)
        #expect(req.Driver == nil)
    }

    @Test func volumeCreateWithName() throws {
        let raw = #"{"Name":"data","Labels":{"x":"y"}}"#
        let req = try JSONDecoder().decode(DockerVolumeCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Name == "data")
        #expect(req.Labels?["x"] == "y")
    }
}

@Suite("DockerExec types")
struct DockerExecTests {
    @Test func execCreateRequestRoundtrip() throws {
        let raw = #"{"Cmd":["ls","-la"],"Tty":true,"AttachStdout":true}"#
        let req = try JSONDecoder().decode(DockerExecCreateRequest.self, from: Data(raw.utf8))
        #expect(req.Cmd == ["ls", "-la"])
        #expect(req.Tty == true)
        #expect(req.AttachStdout == true)
        #expect(req.AttachStderr == nil)
    }

    @Test func execCreateResponse() throws {
        let r = DockerExecCreateResponse(Id: "exec-1")
        let data = try JSONEncoder().encode(r)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["Id"] as? String == "exec-1")
    }

    @Test func execStartRequest() throws {
        let raw = #"{"Detach":false,"Tty":true}"#
        let req = try JSONDecoder().decode(DockerExecStartRequest.self, from: Data(raw.utf8))
        #expect(req.Detach == false)
        #expect(req.Tty == true)
    }
}

@Suite("DockerErrorResponse + Event")
struct DockerErrorAndEventTests {
    @Test func errorResponseEncodesMessage() throws {
        let err = DockerErrorResponse(message: "no such container: abc")
        let data = try JSONEncoder().encode(err)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["message"] as? String == "no such container: abc")
    }

    @Test func eventRemapsTypeKey() throws {
        let evt = DockerEvent(
            status: "start", id: "abc", from: "alpine:latest",
            eventType: "container", Action: "start",
            Actor: DockerEvent.DockerActor(ID: "abc", Attributes: [:]),
            scope: "local", time: 1_700_000_000, timeNano: 1_700_000_000_000_000_000
        )
        let data = try JSONEncoder().encode(evt)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // eventType is encoded as "Type" via CodingKeys.
        #expect(dict?["Type"] as? String == "container")
        #expect(dict?["eventType"] == nil)
        #expect(dict?["Action"] as? String == "start")
    }
}
