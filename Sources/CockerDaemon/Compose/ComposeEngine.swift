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

        /// Compose long-form `depends_on : <service> : { condition : ... }`
        /// expanded into a [serviceName : conditionString] dict. Short-form
        /// (just an array of names) is treated as `service_started`,
        /// matching Docker Compose's default.
        var conditions: [String: String] {
            switch self {
            case .array(let a):
                return Dictionary(uniqueKeysWithValues: a.map { ($0, "service_started") })
            case .dict(let d):
                return Dictionary(uniqueKeysWithValues: d.map { name, spec in
                    (name, spec.condition ?? "service_started")
                })
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
        var ports: PortsSpec?
        var volumes: VolumesSpec?
        var networks: NetworksSpec?
        var depends_on: DependsOnSpec?
        var restart: String?
        // Compose accepts labels as a {key:value} map OR a ["key=value", ...]
        // array. EnvSpec already implements that flexibility.
        var labels: EnvSpec?
        var hostname: String?
        var user: String?
        var working_dir: String?
        var mem_limit: String?
        var cpus: Double?
        var healthcheck: ComposeHealthcheck?
        var deploy: ComposeDeploy?
        var container_name: String?
        var env_file: EnvFileSpec?
        var extra_hosts: [String]?
        var profiles: [String]?
    }

    /// `ports:` entries are either the short string form (`"8080:80/udp"`)
    /// or a mapping. Only `[String]` was modelled, so a file using the long
    /// syntax — which is what `docker compose config` emits — was rejected
    /// outright. Both normalise to the short form the rest of the code reads.
    struct PortsSpec: Decodable {
        var specs: [String]

        struct LongForm: Decodable {
            var target: Int?
            var published: PublishedValue?
            var protocolName: String?
            var host_ip: String?

            enum CodingKeys: String, CodingKey {
                case target, published, host_ip
                case protocolName = "protocol"
            }

            /// `published:` is a number in the spec but quoted by plenty of
            /// generators, and may be a range.
            enum PublishedValue: Decodable {
                case int(Int), text(String)
                init(from decoder: Decoder) throws {
                    if let i = try? decoder.singleValueContainer().decode(Int.self) { self = .int(i) }
                    else { self = .text(try decoder.singleValueContainer().decode(String.self)) }
                }
                var string: String {
                    switch self {
                    case .int(let i): return String(i)
                    case .text(let t): return t
                    }
                }
            }

            var shortForm: String? {
                guard let target else { return nil }
                var out = ""
                if let host_ip, !host_ip.isEmpty { out += "\(host_ip):" }
                if let published { out += "\(published.string):" }
                out += String(target)
                if let proto = protocolName?.lowercased(), proto != "tcp" { out += "/\(proto)" }
                return out
            }
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var collected: [String] = []
            while !container.isAtEnd {
                if let short = try? container.decode(String.self) {
                    collected.append(short)
                } else if let long = try? container.decode(LongForm.self), let short = long.shortForm {
                    collected.append(short)
                } else if let number = try? container.decode(Int.self) {
                    // `- 8080` unquoted.
                    collected.append(String(number))
                } else {
                    _ = try? container.decode(AnyIgnored.self)
                }
            }
            self.specs = collected
        }
    }

    /// Same story for `volumes:` — long syntax rejected the whole file, so
    /// `type: tmpfs` and `read_only: true` were unreachable.
    struct VolumesSpec: Decodable {
        var specs: [String]

        struct LongForm: Decodable {
            var type: String?
            var source: String?
            var target: String?
            var read_only: Bool?

            var shortForm: String? {
                guard let target else { return nil }
                // A tmpfs mount has no source; the short form can't express
                // it, so it's dropped here rather than mounted as a bind of
                // an empty path. Callers see it missing, not wrong.
                guard let source, !source.isEmpty else { return nil }
                return read_only == true ? "\(source):\(target):ro" : "\(source):\(target)"
            }
        }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var collected: [String] = []
            while !container.isAtEnd {
                if let short = try? container.decode(String.self) {
                    collected.append(short)
                } else if let long = try? container.decode(LongForm.self), let short = long.shortForm {
                    collected.append(short)
                } else {
                    _ = try? container.decode(AnyIgnored.self)
                }
            }
            self.specs = collected
        }
    }

    /// `env_file:` accepts a string, a list of strings, or a list of
    /// `{path:, required:}` mappings. Only the first two decoded.
    struct EnvFileSpec: Decodable {
        var paths: [String]

        struct LongForm: Decodable {
            var path: String
            var required: Bool?
        }

        init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                self.paths = [single]
                return
            }
            var container = try decoder.unkeyedContainer()
            var collected: [String] = []
            while !container.isAtEnd {
                if let short = try? container.decode(String.self) {
                    collected.append(short)
                } else if let long = try? container.decode(LongForm.self) {
                    collected.append(long.path)
                } else {
                    _ = try? container.decode(AnyIgnored.self)
                }
            }
            self.paths = collected
        }
    }

    /// Placeholder that consumes one unkeyed element we can't interpret, so
    /// the decoder advances instead of spinning.
    struct AnyIgnored: Decodable {
        init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer() }
    }

    /// `build:` accepts either a bare context path (`build: ./frontend`) or a
    /// mapping. Only the mapping was modelled, so the short form — which is
    /// what most compose files use — made the YAML decode fail and took the
    /// *entire file* down with `invalidComposeFile`.
    struct ComposeBuild: Decodable {
        var context: String?
        var dockerfile: String?
        var args: ArgsSpec?
        /// Multi-stage target. Silently absent before, so a compose file
        /// naming a stage built the last one instead.
        var target: String?

        init(from decoder: Decoder) throws {
            if let shorthand = try? decoder.singleValueContainer().decode(String.self) {
                self.context = shorthand
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.context = try c.decodeIfPresent(String.self, forKey: .context)
            self.dockerfile = try c.decodeIfPresent(String.self, forKey: .dockerfile)
            self.args = try c.decodeIfPresent(ArgsSpec.self, forKey: .args)
            self.target = try c.decodeIfPresent(String.self, forKey: .target)
        }

        enum CodingKeys: String, CodingKey { case context, dockerfile, args, target }

        /// `args:` is a map or a `KEY=value` list, like `environment:`.
        /// Only the map form decoded, so the list form rejected the file.
        enum ArgsSpec: Decodable {
            case map([String: String])
            case list([String])

            init(from decoder: Decoder) throws {
                if let m = try? [String: String](from: decoder) { self = .map(m) }
                else { self = .list(try [String](from: decoder)) }
            }

            var dictionary: [String: String] {
                switch self {
                case .map(let m): return m
                case .list(let l):
                    var out: [String: String] = [:]
                    for entry in l {
                        let parts = entry.split(separator: "=", maxSplits: 1)
                        if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
                        else { out[entry] = "" }
                    }
                    return out
                }
            }
        }
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
        var start_period: String?
        var disable: Bool?

        // Compose v3.4+ canonical is `start_period` (snake_case), but
        // hand-written files and a few generators emit `startPeriod`
        // (camelCase) — both reach us as the same field.
        enum CodingKeys: String, CodingKey {
            case test, interval, timeout, retries, disable
            case start_period
            case startPeriod
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            test     = try c.decodeIfPresent(StringOrArray.self, forKey: .test)
            interval = try c.decodeIfPresent(String.self, forKey: .interval)
            timeout  = try c.decodeIfPresent(String.self, forKey: .timeout)
            retries  = try c.decodeIfPresent(Int.self, forKey: .retries)
            disable  = try c.decodeIfPresent(Bool.self, forKey: .disable)
            start_period = try c.decodeIfPresent(String.self, forKey: .start_period)
                        ?? c.decodeIfPresent(String.self, forKey: .startPeriod)
        }
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
        let projectName = ProjectName.normalize(request.projectName ?? inferProjectName(from: request.composePath))

        progressHandler(StreamEvent(stream: .status, data: "Starting project: \(projectName)\n"))

        // `--remove-orphans` : drop containers still labelled for this project
        // whose service the compose file no longer declares. The flag was
        // declared on both `up` and `down` and referenced nowhere, so a
        // renamed or deleted service left its container running forever with
        // no way to reach it through compose.
        //
        // `down` needs no equivalent — it already sweeps every container
        // carrying the project label, orphan or not.
        if request.removeOrphans {
            let known = Set(compose.services.keys)
            let all = await containerEngine.list(all: true)
            for container in all where container.labels["com.cocker.project"] == projectName {
                guard let service = container.labels["com.cocker.service"],
                      !known.contains(service) else { continue }
                try? await containerEngine.stop(id: container.id)
                try? await containerEngine.remove(id: container.id, force: true)
                progressHandler(StreamEvent(stream: .status,
                    data: "Removed orphan container: \(container.name)\n"))
            }
        }

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

        // Filter out services in profiles that weren't activated. Docker
        // Compose semantics : a service with `profiles:` only starts if one
        // of its profiles is explicitly requested via --profile (or if the
        // user listed the service name on the command line).
        let activeProfiles = Set(request.activeProfiles ?? [])
        let explicit = Set(request.services)
        let candidateServices = compose.services.filter { name, svc in
            // If the user asked for this service by name, run it regardless.
            if explicit.contains(name) { return true }
            // Service with no profiles → always part of the default project.
            guard let profiles = svc.profiles, !profiles.isEmpty else { return true }
            // Service has profiles → only run if at least one is active.
            return !activeProfiles.isDisjoint(with: profiles)
        }.map(\.key)

        // Sort services by dependency order
        let services = request.services.isEmpty ? candidateServices : request.services
        let sorted = topologicalSort(services: services, dependencies: compose.services)

        // Build images for any service with a `build:` block whose tag isn't
        // already in the local store. Without this, `compose up` on a fresh
        // project tries to pull a non-existent `<project>_<svc>:latest` from
        // Docker Hub and falls over.
        //
        // PRO-51 : when the CLI passes `--build`, `request.forceBuild` is
        // true and we drop the "skip if exists" short-circuit, then untag
        // the stale image so the new build doesn't get rejected by an
        // `image already exists` guard further down the pipeline. Matches
        // `docker compose up --build`.
        for serviceName in sorted {
            guard let service = compose.services[serviceName],
                  let buildSpec = service.build else { continue }
            let tag = service.image ?? "\(projectName)_\(serviceName)"
            let alreadyExists = await containerEngine.images.exists(tag)
            if alreadyExists && !request.forceBuild { continue }
            if alreadyExists && request.forceBuild {
                // Best-effort untag — failure here is non-fatal (the rebuild
                // would have failed louder if it really mattered).
                try? await containerEngine.images.remove(tag, force: true)
            }
            // Resolve build context relative to the compose file's directory.
            let composeDir = (request.composePath as NSString).deletingLastPathComponent
            let rawContext = buildSpec.context ?? "."
            let absContext = rawContext.hasPrefix("/")
                ? rawContext
                : "\(composeDir)/\(rawContext)"
            progressHandler(StreamEvent(stream: .status, data: "Building \(serviceName)...\n"))
            var bc = BuildConfig(contextPath: absContext, tag: tag)
            bc.dockerfile = buildSpec.dockerfile ?? "Dockerfile"
            bc.buildArgs = buildSpec.args?.dictionary ?? [:]
            // `target:` was never carried through, so a compose file naming a
            // multi-stage target silently built the final stage instead.
            bc.target = buildSpec.target
            _ = try await containerEngine.images.build(config: bc, vmRuntime: containerEngine.vmRuntime) { event in
                progressHandler(event)
            }
        }

        // Map serviceName → containerName for healthcheck waits below.
        var startedContainers: [String: String] = [:]

        // Start services
        for serviceName in sorted {
            guard let service = compose.services[serviceName] else { continue }

            // depends_on with condition: service_healthy / service_started /
            // service_completed_successfully — block until the dependency is
            // in the requested state before this service boots. Without
            // this, an app starts before its database is reachable and
            // crashes in a hot loop while compose declares success.
            if let deps = service.depends_on?.conditions {
                for (depName, condition) in deps {
                    guard let depContainer = startedContainers[depName] else { continue }
                    progressHandler(StreamEvent(stream: .status,
                        data: " Waiting for \(depName) (\(condition))...\n"))
                    try await waitForCondition(
                        containerName: depContainer,
                        condition: condition,
                        progressHandler: progressHandler
                    )
                }
            }

            progressHandler(StreamEvent(stream: .status, data: "Starting \(projectName)_\(serviceName)_1...\n"))

            let runConfig = try buildRunConfig(
                service: service,
                serviceName: serviceName,
                projectName: projectName,
                compose: compose,
                composePath: request.composePath
            )

            // Pre-emptively delete any existing container with the same
            // name. docker compose's default behavior is to RECREATE
            // services on `up` (unless --no-recreate is passed) ; cocker
            // used to throw `Container name already in use` if the user
            // ran `compose up` twice in a row without a clean `down`
            // first, which made every iteration feel broken. Now we
            // align with docker compose : an existing container with
            // the project's service name is implicitly replaced.
            let serviceContainerName = runConfig.name ?? "\(projectName)_\(serviceName)_1"
            if await containerEngine.state.nameExists(serviceContainerName) {
                _ = try? await containerEngine.remove(id: serviceContainerName, force: true)
            }

            let id = try await containerEngine.run(config: runConfig)
            startedContainers[serviceName] = runConfig.name ?? id

            // Charter §2 (Explicit) : when the service publishes ports, tell the
            // user where to reach it. The data is already in `runConfig.ports` —
            // we surface a clickable localhost URL per published port so a web
            // dev knows exactly what to open, instead of guessing.
            let portSuffix: String
            if runConfig.ports.isEmpty {
                portSuffix = ""
            } else {
                let urls = runConfig.ports
                    .map { "http://localhost:\($0.hostPort)" }
                    .joined(separator: ", ")
                portSuffix = "  -> \(urls)"
            }
            progressHandler(StreamEvent(stream: .stdout, data: " Container \(projectName)_\(serviceName)_1 Started (id: \(String(id.prefix(12))))\(portSuffix)\n"))
        }

        progressHandler(StreamEvent(stream: .status, data: "All services started.\n"))
    }

    /// Block until the given container reaches the Compose `condition:`
    /// state. Polls every 500 ms with a 5-minute ceiling — long enough for
    /// real database boots, short enough that a stuck container surfaces
    /// instead of compose hanging forever.
    ///
    /// - `service_started` : container.status == .running (Docker default)
    /// - `service_healthy` : healthStatus == .healthy
    /// - `service_completed_successfully` : container.status == .stopped
    ///   with exitCode == 0
    private func waitForCondition(containerName: String,
                                  condition: String,
                                  progressHandler: @escaping (StreamEvent) -> Void) async throws {
        let deadline = Date().addingTimeInterval(5 * 60)
        while Date() < deadline {
            let c = await containerEngine.state.container(id: containerName)
            switch condition {
            case "service_started":
                if c?.status == .running { return }
            case "service_healthy":
                if c?.healthStatus == .healthy { return }
                // If the container has no healthcheck, behave like Docker
                // and fall back to service_started after a sanity check.
                if c?.healthcheck == nil && c?.status == .running {
                    progressHandler(StreamEvent(stream: .status,
                        data: "  (no healthcheck on \(containerName) ; treating as healthy)\n"))
                    return
                }
                if c?.healthStatus == .unhealthy {
                    throw CockerError.requestFailed("\(containerName) reported unhealthy")
                }
            case "service_completed_successfully":
                if c?.status == .stopped && (c?.exitCode ?? 0) == 0 { return }
                if c?.status == .stopped && (c?.exitCode ?? 0) != 0 {
                    throw CockerError.requestFailed(
                        "\(containerName) exited with code \(c?.exitCode ?? -1)")
                }
            default:
                // Unknown condition → don't block (matches Docker's
                // tolerant behaviour for forward-compat).
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw CockerError.requestFailed(
            "Timeout waiting for \(containerName) (\(condition)) ; aborted after 5 minutes")
    }

    func build(request: ComposeRequest, progressHandler: @escaping (StreamEvent) -> Void) async throws {
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = ProjectName.normalize(request.projectName ?? inferProjectName(from: request.composePath))
        let services = request.services.isEmpty ? Array(compose.services.keys) : request.services

        // Resolve every build context relative to the compose file's own
        // directory — NOT the daemon's cwd. `compose up --build` already does
        // this (see above) ; `compose build` must match, otherwise a relative
        // `context: ./webapp/api` resolves against wherever cockerd happens to
        // run and the Dockerfile is "not found". PRO-78.
        let composeDir = (request.composePath as NSString).deletingLastPathComponent
        for serviceName in services {
            guard let service = compose.services[serviceName],
                  let buildSpec = service.build else { continue }
            let rawContext = buildSpec.context ?? "."
            let context = rawContext.hasPrefix("/") ? rawContext : "\(composeDir)/\(rawContext)"
            let dockerfile = buildSpec.dockerfile ?? "Dockerfile"
            let tag = service.image ?? "\(projectName)_\(serviceName)"
            progressHandler(StreamEvent(stream: .status, data: "Building \(serviceName)...\n"))
            var config = BuildConfig(contextPath: context, tag: tag)
            config.dockerfile = dockerfile
            config.buildArgs = buildSpec.args?.dictionary ?? [:]
            config.target = buildSpec.target
            config.noCache = request.noCache
            _ = try await containerEngine.images.build(config: config, vmRuntime: containerEngine.vmRuntime) { event in
                progressHandler(event)
            }
            progressHandler(StreamEvent(stream: .status, data: "Built \(tag)\n"))
        }
    }

    func pull(request: ComposeRequest, progressHandler: @escaping (StreamEvent) -> Void) async throws {
        let compose = try loadComposeFile(at: request.composePath)
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
        let projectName = ProjectName.normalize(request.projectName ?? inferProjectName(from: request.composePath))
        let serviceName = request.services.first ?? ""

        guard let service = compose.services[serviceName] else {
            throw CockerError.invalidComposeFile("Service '\(serviceName)' not found")
        }

        var runConfig = try buildRunConfig(service: service, serviceName: serviceName, projectName: projectName, compose: compose, composePath: request.composePath)
        // `compose run <svc> <cmd...>` : the override was parsed by the CLI,
        // never carried on the wire, and the service silently ran its
        // compose-file command instead.
        if let override = request.command, !override.isEmpty {
            runConfig.command = override
        }
        // `--rm` was declared and never referenced, so one-off containers
        // accumulated after every `compose run`.
        runConfig.rm = request.removeAfterRun
        // A one-off run gets its own container: reusing the service's name
        // would collide with an `up` of the same project.
        runConfig.name = nil
        let id = try await containerEngine.run(config: runConfig)
        progressHandler(StreamEvent(stream: .status, data: "Started container \(String(id.prefix(12)))\n"))
    }

    func down(request: ComposeRequest) async throws {
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = ProjectName.normalize(request.projectName ?? inferProjectName(from: request.composePath))

        // Find every container belonging to this project via the label we
        // stamp at create-time. The previous name-based lookup missed
        // services declared with an explicit `container_name:` and any
        // future containers we add (e.g. one-off `compose run`).
        let all = await containerEngine.list(all: true)
        let projectContainers = all.filter { $0.labels["com.cocker.project"] == projectName }
        for container in projectContainers {
            try? await containerEngine.stop(id: container.id)
            try? await containerEngine.remove(id: container.id, force: true)
        }
        // Fallback : also clean up by the conventional name pattern in case
        // the labels were stripped (older containers from earlier versions).
        for serviceName in compose.services.keys {
            let containerName = "\(projectName)_\(serviceName)_1"
            let containers = await containerEngine.list(all: true, filter: ["name": containerName])
            for container in containers {
                try? await containerEngine.stop(id: container.id)
                try? await containerEngine.remove(id: container.id, force: true)
            }
        }

        // Supprime aussi les networks créés par ce projet (préfixés par projectName_).
        // force: true → nettoie les références dangling de containers déjà supprimés.
        if let networks = compose.networks {
            for (name, netSpec) in networks where netSpec.external != true {
                let fullName = "\(projectName)_\(name)"
                try? await containerEngine.networks.remove(fullName, force: true)
            }
        }

        // `--volumes` : drop named volumes the project created. External
        // volumes (`external: true`) are left alone — the user opted into
        // managing them outside compose's lifecycle. Bind mounts are never
        // touched (they live on the host filesystem and aren't ours).
        //
        // force: true is critical here. Without it, `volumes.remove` checks
        // every container in state.json for references and refuses if any
        // exists ; stale records of just-removed containers can linger for
        // a tick under load and silently fail the rm via try?. The result
        // user sees : `compose up` later reuses the SAME data.img, postgres
        // entrypoint says "Database directory appears to contain a
        // database; Skipping initialization", POSTGRES_HOST_AUTH_METHOD
        // never re-applies, every cnet client gets "no pg_hba.conf entry
        // for host". By force-deleting here we always start from a fresh
        // mkfs.ext4'd data.img on the next compose up.
        if request.removeVolumes, let volumes = compose.volumes {
            for (name, volSpec) in volumes {
                let spec = volSpec ?? ComposeFile.ComposeVolumeSpec()
                if spec.external == true { continue }
                let fullName = "\(projectName)_\(name)"
                try? await containerEngine.volumes.remove(fullName, force: true)
            }
        }
    }

    // MARK: - Helpers

    private func loadComposeFile(at path: String) throws -> ComposeFile {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CockerError.invalidComposeFile("Cannot read file: \(path)")
        }
        // Docker Compose variable substitution: ${VAR}, ${VAR:-default},
        // ${VAR-default}, $VAR, $$. Without this, a compose file that uses
        // ${POSTGRES_USER:-cidgroupe} would pass the literal string (with
        // `$`, `{`, etc.) as an env var value into the container — which
        // breaks anything that validates input chars (e.g. postgres
        // "invalid character in extension owner").
        let composeDir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let subEnv = Self.composeSubstitutionEnv(composeDir: composeDir)
        let expanded = Self.expandVariables(in: content, env: subEnv)
        do {
            return try YAMLDecoder().decode(ComposeFile.self, from: expanded)
        } catch {
            throw CockerError.invalidComposeFile("YAML parse error: \(error)")
        }
    }

    /// Build the env map used for `${VAR}` substitution in the compose file.
    /// Per the Compose spec, values come from the project `.env` file in the
    /// compose dir (if present), then host environment wins on conflict.
    static func composeSubstitutionEnv(composeDir: String) -> [String: String] {
        var env: [String: String] = [:]
        let dotEnv = composeDir + "/.env"
        if FileManager.default.fileExists(atPath: dotEnv) {
            for (k, v) in parseEnvFile(at: dotEnv) { env[k] = v }
        }
        // Host env overrides .env (Compose precedence)
        for (k, v) in ProcessInfo.processInfo.environment { env[k] = v }
        return env
    }

    /// Parse a KEY=VALUE env file (Docker `--env-file` / Compose `env_file`).
    /// Strips matching surrounding quotes ; ignores blank lines and `#` comments.
    static func parseEnvFile(at path: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return result
        }
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    /// Expand `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?msg}`,
    /// `${VAR?msg}`, `$VAR` ; `$$` escapes to a literal `$`. Anything that
    /// doesn't parse as a variable reference is passed through untouched.
    static func expandVariables(in input: String, env: [String: String]) -> String {
        var out = ""
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c != "$" {
                out.append(c)
                i = input.index(after: i)
                continue
            }
            let next = input.index(after: i)
            guard next < input.endIndex else {
                out.append(c)
                i = next
                continue
            }
            let nc = input[next]
            if nc == "$" {
                out.append("$")
                i = input.index(after: next)
                continue
            }
            if nc == "{" {
                if let close = input[next...].firstIndex(of: "}") {
                    let body = String(input[input.index(after: next)..<close])
                    out += resolveComposeVar(body, env: env)
                    i = input.index(after: close)
                    continue
                }
                out.append(c)
                i = next
                continue
            }
            if nc.isLetter || nc == "_" {
                var end = next
                while end < input.endIndex {
                    let ch = input[end]
                    if ch.isLetter || ch.isNumber || ch == "_" {
                        end = input.index(after: end)
                    } else { break }
                }
                let name = String(input[next..<end])
                out += env[name] ?? ""
                i = end
                continue
            }
            out.append(c)
            i = next
        }
        return out
    }

    private static func resolveComposeVar(_ body: String, env: [String: String]) -> String {
        // Order matters: 2-char ops first so `:-` isn't matched as bare `-`.
        for op in [":-", ":?", "-", "?"] {
            if let range = body.range(of: op) {
                let name = String(body[..<range.lowerBound])
                let rest = String(body[range.upperBound...])
                let value = env[name]
                switch op {
                case ":-":
                    if let v = value, !v.isEmpty { return v }
                    return rest
                case "-":
                    return value ?? rest
                case ":?":
                    if let v = value, !v.isEmpty { return v }
                    return ""
                case "?":
                    return value ?? ""
                default: break
                }
            }
        }
        return env[body] ?? ""
    }

    private func inferProjectName(from path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    private func buildRunConfig(
        service: ComposeFile.ComposeService,
        serviceName: String,
        projectName: String,
        compose: ComposeFile,
        composePath: String
    ) throws -> RunConfig {
        let image = service.image ?? "\(projectName)_\(serviceName)"
        var config = RunConfig(image: image)

        config.name = service.container_name ?? "\(projectName)_\(serviceName)_1"
        config.detach = true
        config.hostname = service.hostname ?? serviceName

        if let cmd = service.command {
            // `command: "npm run dev"` (string form) is shell form in compose,
            // exactly like Dockerfile CMD. Passing it through as a single
            // argv element made the guest try to exec a file literally named
            // "npm run dev" — ENOENT, every time. The array form is exec form
            // and passes through verbatim.
            switch cmd {
            case .string(let line): config.command = ["/bin/sh", "-c", line]
            case .array(let argv): config.command = argv
            }
        }

        // `entrypoint:` was decoded and then never read, so overriding an
        // image's ENTRYPOINT through compose was impossible.
        if let entrypoint = service.entrypoint {
            switch entrypoint {
            case .string(let line): config.entrypoint = ["/bin/sh", "-c", line]
            case .array(let argv): config.entrypoint = argv
            }
        }

        // env_file is the lowest-priority layer ; `environment:` overrides it.
        // Paths are relative to the compose file's directory.
        if let envFile = service.env_file {
            let baseDir = URL(fileURLWithPath: composePath).deletingLastPathComponent()
            for p in envFile.paths {
                let fullPath = p.hasPrefix("/") ? p : baseDir.appendingPathComponent(p).path
                for (k, v) in Self.parseEnvFile(at: fullPath) {
                    config.env[k] = v
                }
            }
        }

        if let env = service.environment {
            for (k, v) in env.dict { config.env[k] = v }
        }

        // Ports
        // `compactMap { try? }` swallowed every entry the old parser couldn't
        // handle — ranges, udp, a host bind address — so the port was never
        // published and nothing said so. A port the user asked for and didn't
        // get is worth failing the service over.
        config.ports = try (service.ports?.specs ?? []).flatMap { spec -> [PortMapping] in
            do { return try PortMapping.parseSpec(spec) }
            catch {
                throw CockerError.invalidComposeFile(
                    "service '\(serviceName)': cannot parse port '\(spec)'")
            }
        }

        // Volumes
        let composeDir = (composePath as NSString).deletingLastPathComponent
        config.volumes = (service.volumes?.specs ?? []).compactMap { s in
            let parts = s.split(separator: ":", maxSplits: 2).map(String.init)
            // Single-part volume entry like `- /app/node_modules` is a
            // Docker Compose ANONYMOUS volume — a per-container managed
            // volume that "shadows" whatever's at that path inside the
            // container (typical Node pattern : keep the image's Linux
            // node_modules instead of letting the bind-mounted ./backend
            // overwrite it with the host's). NOT a host bind mount.
            if parts.count == 1 {
                let dest = parts[0]
                let normalized = dest
                    .replacingOccurrences(of: "/", with: "_")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                let anonName = "\(projectName)_\(serviceName)_anon_\(normalized)"
                return VolumeMount(source: anonName, destination: dest)
            }
            if parts.count >= 2 {
                let ro = parts.count == 3 && parts[2] == "ro"
                let rawSrc = parts[0]
                let src: String
                if rawSrc.hasPrefix("/") {
                    // Absolute host path → bind mount.
                    src = rawSrc
                } else if rawSrc.hasPrefix("./") || rawSrc.hasPrefix("../") || rawSrc.contains("/") {
                    // Compose-spec relative bind mount (`./backend`,
                    // `../shared`, `subdir/foo`) — resolve against the
                    // compose file's directory and pass to the volume
                    // resolver as an absolute path so it's treated as a
                    // bind mount, NOT a named volume.
                    let resolved = URL(fileURLWithPath: composeDir)
                        .appendingPathComponent(rawSrc)
                        .standardizedFileURL
                        .path
                    src = resolved
                } else {
                    // No slash → genuine named volume reference. Prefix
                    // with project name to namespace per project.
                    src = "\(projectName)_\(rawSrc)"
                }
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

        config.labels = service.labels?.dict ?? [:]
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

        // Healthcheck. Compose accepts the test as either a string (run via
        // shell) or an array. Array form may start with "CMD" / "CMD-SHELL"
        // / "NONE" or be a raw exec argv. We translate into the same
        // health* fields the CLI flags use ; ContainerEngine.mergeHealthcheck
        // handles precedence vs. the image's HEALTHCHECK.
        if let hc = service.healthcheck {
            if hc.disable == true {
                config.healthDisable = true
            } else if let test = hc.test {
                let arr = test.array
                // Case-insensitive NONE : some hand-written compose files
                // use lowercase even though the spec says uppercase.
                if (arr.first?.uppercased() ?? "") == "NONE" {
                    config.healthDisable = true
                } else if arr.first == "CMD-SHELL", arr.count >= 2 {
                    config.healthCmd = arr.dropFirst().joined(separator: " ")
                } else if arr.first == "CMD", arr.count >= 2 {
                    // Run the exec form via /bin/sh -c so health_poll's argv
                    // splitter handles it the same way as CLI overrides.
                    config.healthCmd = arr.dropFirst().joined(separator: " ")
                } else {
                    // Plain string OR bare argv (no CMD prefix).
                    config.healthCmd = arr.joined(separator: " ")
                }
            }
            config.healthInterval = hc.interval.flatMap(Self.parseDuration)
            config.healthTimeout = hc.timeout.flatMap(Self.parseDuration)
            config.healthStartPeriod = hc.start_period.flatMap(Self.parseDuration)
            config.healthRetries = hc.retries
        }

        return config
    }

    /// Parse Compose duration strings (same grammar as Docker CLI flags).
    static func parseDuration(_ s: String) -> TimeInterval? {
        let str = s.trimmingCharacters(in: .whitespaces).lowercased()
        if str.isEmpty { return nil }
        if let n = Double(str) { return n }
        let suffixes: [(String, Double)] = [
            ("ms", 0.001), ("us", 0.000001), ("ns", 0.000000001),
            ("s", 1), ("m", 60), ("h", 3600)
        ]
        for (suf, mult) in suffixes {
            if str.hasSuffix(suf) {
                let numPart = String(str.dropLast(suf.count))
                if let n = Double(numPart) { return n * mult }
            }
        }
        return nil
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
