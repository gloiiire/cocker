import Testing
import Foundation
import Yams
@testable import CockerDaemon

// Decoding side of ComposeEngine — parsing docker-compose.yml subsets.
// The orchestration side (`ComposeEngine.up/down`) drives a real container
// engine and isn't unit-testable, but the parse must hold the line on every
// dialect a user can throw at us.

private func parse(_ yaml: String) throws -> ComposeFile {
    let decoder = YAMLDecoder()
    return try decoder.decode(ComposeFile.self, from: yaml)
}

@Suite("ComposeFile — minimal")
struct ComposeFileMinimalTests {
    @Test func parsesSingleServiceImage() throws {
        let yaml = """
        services:
          web:
            image: nginx:alpine
        """
        let f = try parse(yaml)
        #expect(f.services.count == 1)
        #expect(f.services["web"]?.image == "nginx:alpine")
    }

    @Test func parsesVersionField() throws {
        let yaml = """
        version: "3.9"
        services:
          a:
            image: alpine
        """
        let f = try parse(yaml)
        #expect(f.version == "3.9")
    }

    @Test func multipleServices() throws {
        let yaml = """
        services:
          web:
            image: nginx
          db:
            image: postgres:16
        """
        let f = try parse(yaml)
        #expect(f.services.count == 2)
        #expect(f.services["db"]?.image == "postgres:16")
    }
}

@Suite("ComposeFile — StringOrArray")
struct ComposeStringOrArrayTests {
    @Test func commandAsString() throws {
        let yaml = """
        services:
          a:
            image: alpine
            command: echo hi
        """
        let f = try parse(yaml)
        if case .string(let s) = f.services["a"]?.command {
            #expect(s == "echo hi")
        } else {
            Issue.record("expected .string case")
        }
        #expect(f.services["a"]?.command?.array == ["echo hi"])
    }

    @Test func commandAsArray() throws {
        let yaml = """
        services:
          a:
            image: alpine
            command: ["echo", "hi"]
        """
        let f = try parse(yaml)
        #expect(f.services["a"]?.command?.array == ["echo", "hi"])
    }

    @Test func entrypointAsArray() throws {
        let yaml = """
        services:
          a:
            image: alpine
            entrypoint:
              - /bin/sh
              - -c
        """
        let f = try parse(yaml)
        #expect(f.services["a"]?.entrypoint?.array == ["/bin/sh", "-c"])
    }
}

@Suite("ComposeFile — EnvSpec")
struct ComposeEnvSpecTests {
    @Test func envAsDict() throws {
        let yaml = """
        services:
          a:
            image: alpine
            environment:
              FOO: bar
              BAZ: qux
        """
        let f = try parse(yaml)
        let env = f.services["a"]?.environment?.dict
        #expect(env?["FOO"] == "bar")
        #expect(env?["BAZ"] == "qux")
    }

    @Test func envAsArrayKVStrings() throws {
        let yaml = """
        services:
          a:
            image: alpine
            environment:
              - FOO=bar
              - BAZ=qux
        """
        let f = try parse(yaml)
        let env = f.services["a"]?.environment?.dict
        #expect(env?["FOO"] == "bar")
        #expect(env?["BAZ"] == "qux")
    }

    @Test func envAsBareKeyResolvesFromProcessEnv() throws {
        setenv("COCKER_TEST_ENV_PASSTHROUGH", "value", 1)
        defer { unsetenv("COCKER_TEST_ENV_PASSTHROUGH") }
        let yaml = """
        services:
          a:
            image: alpine
            environment:
              - COCKER_TEST_ENV_PASSTHROUGH
        """
        let f = try parse(yaml)
        let env = f.services["a"]?.environment?.dict
        #expect(env?["COCKER_TEST_ENV_PASSTHROUGH"] == "value")
    }
}

@Suite("ComposeFile — DependsOnSpec")
struct ComposeDependsOnTests {
    @Test func dependsOnAsArray() throws {
        let yaml = """
        services:
          web:
            image: nginx
            depends_on: ["db", "cache"]
          db:
            image: postgres
          cache:
            image: redis
        """
        let f = try parse(yaml)
        let names = Set(f.services["web"]?.depends_on?.serviceNames ?? [])
        #expect(names == Set(["db", "cache"]))
    }

    @Test func dependsOnAsConditionDict() throws {
        let yaml = """
        services:
          web:
            image: nginx
            depends_on:
              db:
                condition: service_started
          db:
            image: postgres
        """
        let f = try parse(yaml)
        #expect(f.services["web"]?.depends_on?.serviceNames == ["db"])
    }
}

@Suite("ComposeFile — NetworksSpec")
struct ComposeNetworksSpecTests {
    @Test func networksAsArray() throws {
        let yaml = """
        services:
          a:
            image: alpine
            networks: [front, back]
        """
        let f = try parse(yaml)
        #expect(Set(f.services["a"]?.networks?.networkNames ?? []) == Set(["front", "back"]))
    }

    @Test func networksAsDictWithAliases() throws {
        let yaml = """
        services:
          a:
            image: alpine
            networks:
              front:
                aliases: [primary, web]
        """
        let f = try parse(yaml)
        let net = f.services["a"]?.networks
        #expect(net?.networkNames == ["front"])
        #expect(Set(net?.aliases(for: "front") ?? []) == Set(["primary", "web"]))
    }
}

@Suite("ComposeFile — networks / volumes blocks")
struct ComposeRootNetworksAndVolumesTests {
    @Test func topLevelNetworkBlock() throws {
        let yaml = """
        services:
          a: {image: alpine}
        networks:
          front:
            driver: bridge
            ipam:
              config:
                - subnet: 10.99.0.0/24
                  gateway: 10.99.0.1
        """
        let f = try parse(yaml)
        #expect(f.networks?["front"]?.driver == "bridge")
        #expect(f.networks?["front"]?.ipam?.config?.first?.subnet == "10.99.0.0/24")
    }

    @Test func topLevelVolumeBlock() throws {
        let yaml = """
        services:
          a: {image: alpine}
        volumes:
          data:
            driver: local
          external-vol:
            external: true
        """
        let f = try parse(yaml)
        // `volumes:` maps to optional values; data block exists.
        #expect(f.volumes?["data"]??.driver == "local")
        #expect(f.volumes?["external-vol"]??.external == true)
    }

    @Test func nullVolumeIsTolerated() throws {
        let yaml = """
        services:
          a: {image: alpine}
        volumes:
          empty:
        """
        let f = try parse(yaml)
        // Key exists, the inner spec may be nil.
        #expect(f.volumes?.keys.contains("empty") == true)
    }
}

@Suite("ComposeFile — build / healthcheck / deploy")
struct ComposeAdvancedTests {
    @Test func buildBlock() throws {
        let yaml = """
        services:
          api:
            build:
              context: ./api
              dockerfile: Dockerfile.dev
              args:
                FOO: bar
        """
        let f = try parse(yaml)
        let b = f.services["api"]?.build
        #expect(b?.context == "./api")
        #expect(b?.dockerfile == "Dockerfile.dev")
        // `args` is now a map-or-list spec (compose accepts both); read it
        // through the normalising accessor.
        #expect(b?.args?.dictionary["FOO"] == "bar")
    }

    @Test func healthcheckTestAsArray() throws {
        let yaml = """
        services:
          a:
            image: alpine
            healthcheck:
              test: ["CMD", "curl", "-f", "http://x"]
              interval: 30s
              timeout: 5s
              retries: 3
        """
        let f = try parse(yaml)
        let hc = f.services["a"]?.healthcheck
        #expect(hc?.test?.array == ["CMD", "curl", "-f", "http://x"])
        #expect(hc?.interval == "30s")
        #expect(hc?.timeout == "5s")
        #expect(hc?.retries == 3)
    }

    @Test func deployBlock() throws {
        let yaml = """
        services:
          a:
            image: alpine
            deploy:
              replicas: 3
              resources:
                limits:
                  cpus: "0.5"
                  memory: 256M
        """
        let f = try parse(yaml)
        let d = f.services["a"]?.deploy
        #expect(d?.replicas == 3)
        #expect(d?.resources?.limits?.cpus == "0.5")
        #expect(d?.resources?.limits?.memory == "256M")
    }

    @Test func portsAndVolumesAsStringArrays() throws {
        let yaml = """
        services:
          a:
            image: alpine
            ports:
              - "8080:80"
              - "443:443"
            volumes:
              - "/host:/guest"
              - "data:/var/lib"
        """
        let f = try parse(yaml)
        #expect(f.services["a"]?.ports == ["8080:80", "443:443"])
        #expect(f.services["a"]?.volumes == ["/host:/guest", "data:/var/lib"])
    }

    @Test func labelsAndLabelsLikeMaps() throws {
        let yaml = """
        services:
          a:
            image: alpine
            labels:
              owner: alice
              env: prod
        """
        let f = try parse(yaml)
        // labels is now an EnvSpec to accept both dict and `["k=v"]` forms.
        #expect(f.services["a"]?.labels?.dict["owner"] == "alice")
        #expect(f.services["a"]?.labels?.dict["env"] == "prod")
    }

    @Test func envFileSingleAndArray() throws {
        let single = """
        services:
          a:
            image: alpine
            env_file: .env
        """
        let multi = """
        services:
          a:
            image: alpine
            env_file:
              - .env
              - .env.local
        """
        let s = try parse(single)
        let m = try parse(multi)
        #expect(s.services["a"]?.env_file?.array == [".env"])
        #expect(m.services["a"]?.env_file?.array == [".env", ".env.local"])
    }
}
