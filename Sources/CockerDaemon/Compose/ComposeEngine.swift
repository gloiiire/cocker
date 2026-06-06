import Foundation
import CockerCore
import Yams

// Compose file format (docker-compose.yml compatible subset)

struct ComposeFile: Decodable {
    var version: String?
    var services: [String: ComposeService]
    var networks: [String: ComposeNetwork]?
    var volumes: [String: ComposeVolumeSpec?]?

    struct DependsOnCondition: Decodable {
        var condition: String?
    }

    enum DependsOnSpec: Decodable {
        case array([String])
        case dict([String: DependsOnCondition])

        init(from decoder: Decoder) throws {
            if let arr = try? [String](from: decoder) {
                self = .array(arr)
            } else if let d = try? [String: DependsOnCondition](from: decoder) {
                self = .dict(d)
            } else {
                self = .array([])
            }
        }

        var serviceNames: [String] {
            switch self {
            case .array(let a): return a
            case .dict(let d): return Array(d.keys)
            }
        }
    }

    struct NetworkServiceSpec: Decodable {
        var aliases: [String]?
    }

    enum NetworksSpec: Decodable {
        case array([String])
        case dict([String: NetworkServiceSpec?])

        init(from decoder: Decoder) throws {
            if let arr = try? [String](from: decoder) {
                self = .array(arr)
            } else if let d = try? [String: NetworkServiceSpec?](from: decoder) {
                self = .dict(d)
            } else {
                self = .array([])
            }
        }

        var networkNames: [String] {
            switch self {
            case .array(let a): return a
            case .dict(let d): return Array(d.keys)
            }
        }

        func aliases(for network: String) -> [String] {
            if case .dict(let d) = self {
                return d[network]??.aliases ?? []
            }
            return []
        }
    }

    struct ComposeService: Decodable {
        var image: String?
        var build: ComposeBuild?
        var command: StringOrArray?
        var entrypoint: StringOrArray?
        var environment: EnvSpec?
        var ports: [String]?
        var volumes: [String]?
        var networks: NetworksSpec?
        var depends_on: DependsOnSpec?
        var restart: String?
        var labels: [String: String]?
        var hostname: String?
        var user: String?
        var working_dir: String?
        var mem_limit: String?
        var cpus: Double?
        var healthcheck: ComposeHealthcheck?
        var deploy: ComposeDeploy?
        var container_name: String?
        var env_file: StringOrArray?
        var extra_hosts: [String]?
    }

    struct ComposeBuild: Decodable {
        var context: String?
        var dockerfile: String?
        var args: [String: String]?
    }

    struct ComposeNetwork: Decodable {
        var driver: String?
        var ipam: ComposeIPAM?
        var external: Bool?
        var name: String?
    }

    struct ComposeIPAM: Decodable {
        var config: [ComposeIPAMConfig]?
        struct ComposeIPAMConfig: Decodable {
            var subnet: String?
            var gateway: String?
        }
    }

    struct ComposeVolumeSpec: Decodable {
        var driver: String?
        var external: Bool?
        var name: String?
    }

    struct ComposeHealthcheck: Decodable {
        var test: StringOrArray?
        var interval: String?
        var timeout: String?
        var retries: Int?
    }

    struct ComposeDeploy: Decodable {
        var replicas: Int?
        var resources: ComposeResources?
        struct ComposeResources: Decodable {
            var limits: ComposeResourceLimits?
            struct ComposeResourceLimits: Decodable {
                var cpus: String?
                var memory: String?
            }
        }
    }

    // Handles both string and array YAML values
    enum StringOrArray: Decodable {
        case string(String)
        case array([String])

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                self = .string(s)
            } else {
                self = .array(try [String](from: decoder))
            }
        }

        var array: [String] {
            switch self {
            case .string(let s): return [s]
            case .array(let a): return a
            }
        }

        var string: String {
            switch self {
            case .string(let s): return s
            case .array(let a): return a.joined(separator: " ")
            }
        }
    }

    // Handles env as dict or array
    enum EnvSpec: Decodable {
        case dict([String: String])
        case array([String])

        init(from decoder: Decoder) throws {
            if let dict = try? [String: String](from: decoder) {
                self = .dict(dict)
            } else {
                self = .array(try [String](from: decoder))
            }
        }

        var dict: [String: String] {
            switch self {
            case .dict(let d): return d
            case .array(let a):
                var result: [String: String] = [:]
                for item in a {
                    let parts = item.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
                    else { result[item] = ProcessInfo.processInfo.environment[item] ?? "" }
                }
                return result
            }
        }
    }
}

// MARK: - Compose Engine

actor ComposeEngine {
    private let containerEngine: ContainerEngine

    init(containerEngine: ContainerEngine) {
        self.containerEngine = containerEngine
    }

    func up(request: ComposeRequest, progressHandler: @escaping (StreamEvent) -> Void) async throws {
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = request.projectName ?? inferProjectName(from: request.composePath)

        progressHandler(StreamEvent(stream: .status, data: "Starting project: \(projectName)\n"))

        // Create networks first
        if let networks = compose.networks {
            for (name, netSpec) in networks where netSpec.external != true {
                let fullName = "\(projectName)_\(name)"
                let driver = NetworkDriver(rawValue: netSpec.driver ?? "bridge") ?? .bridge
                let req = NetworkCreateRequest(name: fullName, driver: driver)
                if let _ = try? await containerEngine.networks.get(fullName) { continue }
                _ = try await containerEngine.networks.create(request: req)
                progressHandler(StreamEvent(stream: .status, data: "Created network: \(fullName)\n"))
            }
        }

        // Create volumes
        if let volumes = compose.volumes {
            for (name, volSpec) in volumes {
                let volSpec = volSpec ?? ComposeFile.ComposeVolumeSpec()
                if volSpec.external == true { continue }
                let fullName = "\(projectName)_\(name)"
                let req = VolumeCreateRequest(name: volSpec.name ?? fullName, driver: volSpec.driver ?? "local")
                if let _ = try? await containerEngine.volumes.get(fullName) { continue }
                _ = try await containerEngine.volumes.create(request: req)
                progressHandler(StreamEvent(stream: .status, data: "Created volume: \(fullName)\n"))
            }
        }

        // Sort services by dependency order
        let services = request.services.isEmpty ? Array(compose.services.keys) : request.services
        let sorted = topologicalSort(services: services, dependencies: compose.services)

        // Start services
        for serviceName in sorted {
            guard let service = compose.services[serviceName] else { continue }
            progressHandler(StreamEvent(stream: .status, data: "Starting \(projectName)_\(serviceName)_1...\n"))

            let runConfig = try buildRunConfig(
                service: service,
                serviceName: serviceName,
                projectName: projectName,
                compose: compose
            )

            let id = try await containerEngine.run(config: runConfig)
            progressHandler(StreamEvent(stream: .stdout, data: " Container \(projectName)_\(serviceName)_1 Started (id: \(String(id.prefix(12))))\n"))
        }

        progressHandler(StreamEvent(stream: .status, data: "All services started.\n"))
    }

    func build(request: ComposeRequest, progressHandler: @escaping (StreamEvent) -> Void) async throws {
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = request.projectName ?? inferProjectName(from: request.composePath)
        let services = request.services.isEmpty ? Array(compose.services.keys) : request.services

        for serviceName in services {
            guard let service = compose.services[serviceName],
                  let buildSpec = service.build else { continue }
            let context = buildSpec.context ?? "."
            let dockerfile = buildSpec.dockerfile ?? "Dockerfile"
            let tag = service.image ?? "\(projectName)_\(serviceName)"
            progressHandler(StreamEvent(stream: .status, data: "Building \(serviceName)...\n"))
            var config = BuildConfig(contextPath: context, tag: tag)
            config.dockerfile = dockerfile
            config.buildArgs = buildSpec.args ?? [:]
            _ = try await containerEngine.images.build(config: config) { event in
                progressHandler(event)
            }
            progressHandler(StreamEvent(stream: .status, data: "Built \(tag)\n"))
        }
    }

    func pull(request: ComposeRequest, progressHandler: @escaping (StreamEvent) -> Void) async throws {
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = request.projectName ?? inferProjectName(from: request.composePath)
        let services = request.services.isEmpty ? Array(compose.services.keys) : request.services

        for serviceName in services {
            guard let service = compose.services[serviceName],
                  let image = service.image else { continue }
            if await containerEngine.images.exists(image) {
                progressHandler(StreamEvent(stream: .status, data: "\(image): Already exists\n"))
                continue
            }
            progressHandler(StreamEvent(stream: .status, data: "Pulling \(image)...\n"))
            _ = try await containerEngine.images.pull(reference: image) { msg in
                progressHandler(StreamEvent(stream: .stdout, data: msg + "\n"))
            }
            progressHandler(StreamEvent(stream: .status, data: "Pulled \(image)\n"))
        }
    }

    func run(request: ComposeRequest, progressHandler: @escaping (StreamEvent) -> Void) async throws {
        // One-off run: start the service's container with detach
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = request.projectName ?? inferProjectName(from: request.composePath)
        let serviceName = request.services.first ?? ""

        guard let service = compose.services[serviceName] else {
            throw CockerError.invalidComposeFile("Service '\(serviceName)' not found")
        }

        let runConfig = try buildRunConfig(service: service, serviceName: serviceName, projectName: projectName, compose: compose)
        let id = try await containerEngine.run(config: runConfig)
        progressHandler(StreamEvent(stream: .status, data: "Started container \(String(id.prefix(12)))\n"))
    }

    func down(request: ComposeRequest) async throws {
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = request.projectName ?? inferProjectName(from: request.composePath)

        // Stop containers in reverse dependency order
        let services = Array(compose.services.keys)
        for serviceName in services.reversed() {
            let containerName = "\(projectName)_\(serviceName)_1"
            let containers = await containerEngine.list(all: true, filter: ["name": containerName])
            for container in containers {
                try? await containerEngine.stop(id: container.id)
                try? await containerEngine.remove(id: container.id, force: true)
            }
        }

        // Supprime aussi les networks créés par ce projet (préfixés par projectName_)
        if let networks = compose.networks {
            for (name, netSpec) in networks where netSpec.external != true {
                let fullName = "\(projectName)_\(name)"
                try? await containerEngine.networks.remove(fullName)
            }
        }
    }

    // MARK: - Helpers

    private func loadComposeFile(at path: String) throws -> ComposeFile {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CockerError.invalidComposeFile("Cannot read file: \(path)")
        }
        do {
            return try YAMLDecoder().decode(ComposeFile.self, from: content)
        } catch {
            throw CockerError.invalidComposeFile("YAML parse error: \(error)")
        }
    }

    private func inferProjectName(from path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    private func buildRunConfig(
        service: ComposeFile.ComposeService,
        serviceName: String,
        projectName: String,
        compose: ComposeFile
    ) throws -> RunConfig {
        let image = service.image ?? "\(projectName)_\(serviceName)"
        var config = RunConfig(image: image)

        config.name = service.container_name ?? "\(projectName)_\(serviceName)_1"
        config.detach = true
        config.hostname = service.hostname ?? serviceName

        if let cmd = service.command {
            config.command = cmd.array
        }

        if let env = service.environment {
            config.env = env.dict
        }

        // Ports
        config.ports = (service.ports ?? []).compactMap { try? PortMapping.parse($0) }

        // Volumes
        config.volumes = (service.volumes ?? []).compactMap { s in
            let parts = s.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 1 { return VolumeMount(source: parts[0], destination: parts[0]) }
            if parts.count >= 2 {
                let ro = parts.count == 3 && parts[2] == "ro"
                // Prefix named volumes with project name
                let src = parts[0].hasPrefix("/") ? parts[0] : "\(projectName)_\(parts[0])"
                return VolumeMount(source: src, destination: parts[1], readOnly: ro)
            }
            return nil
        }

        // Memory
        if let mem = service.mem_limit {
            config.memoryMB = parseMemory(mem)
        }

        if let cpus = service.cpus {
            config.cpuCount = max(1, Int(cpus))
        }

        config.labels = service.labels ?? [:]
        config.labels["com.cocker.project"] = projectName
        config.labels["com.cocker.service"] = serviceName

        config.restartPolicy = RestartPolicy(rawValue: service.restart ?? "no") ?? .no

        // Network
        if let netSpec = service.networks {
            let netNames = netSpec.networkNames
            config.network = netNames.first.map { "\(projectName)_\($0)" }
            // Store aliases in labels
            if let firstNet = netNames.first {
                let aliases = netSpec.aliases(for: firstNet)
                if !aliases.isEmpty {
                    config.labels["com.cocker.aliases"] = aliases.joined(separator: ",")
                }
            }
        }

        // extra_hosts → stored in labels for the VM to use
        if let extraHosts = service.extra_hosts, !extraHosts.isEmpty {
            config.labels["com.cocker.extra_hosts"] = extraHosts.joined(separator: ";")
        }

        config.workdir = service.working_dir
        config.user = service.user

        return config
    }

    private func topologicalSort(services: [String], dependencies: [String: ComposeFile.ComposeService]) -> [String] {
        var sorted: [String] = []
        var visited = Set<String>()

        func visit(_ name: String) {
            guard !visited.contains(name) else { return }
            visited.insert(name)
            if let deps = dependencies[name]?.depends_on?.serviceNames {
                for dep in deps { visit(dep) }
            }
            sorted.append(name)
        }

        for service in services { visit(service) }
        return sorted
    }

    private func parseMemory(_ s: String) -> UInt64 {
        let lower = s.lowercased()
        if lower.hasSuffix("g") { return (UInt64(lower.dropLast()) ?? 1) * 1024 }
        if lower.hasSuffix("m") { return UInt64(lower.dropLast()) ?? 512 }
        if lower.hasSuffix("k") { return (UInt64(lower.dropLast()) ?? 512) / 1024 }
        return UInt64(s) ?? 512
    }
}
