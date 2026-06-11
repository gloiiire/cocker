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
        var ports: [String]?
        var volumes: [String]?
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
        var env_file: StringOrArray?
        var extra_hosts: [String]?
        var profiles: [String]?
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
        for serviceName in sorted {
            guard let service = compose.services[serviceName],
                  let buildSpec = service.build else { continue }
            let tag = service.image ?? "\(projectName)_\(serviceName)"
            if await containerEngine.images.exists(tag) { continue }
            // Resolve build context relative to the compose file's directory.
            let composeDir = (request.composePath as NSString).deletingLastPathComponent
            let rawContext = buildSpec.context ?? "."
            let absContext = rawContext.hasPrefix("/")
                ? rawContext
                : "\(composeDir)/\(rawContext)"
            progressHandler(StreamEvent(stream: .status, data: "Building \(serviceName)...\n"))
            var bc = BuildConfig(contextPath: absContext, tag: tag)
            bc.dockerfile = buildSpec.dockerfile ?? "Dockerfile"
            bc.buildArgs = buildSpec.args ?? [:]
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

            let id = try await containerEngine.run(config: runConfig)
            startedContainers[serviceName] = runConfig.name ?? id
            progressHandler(StreamEvent(stream: .stdout, data: " Container \(projectName)_\(serviceName)_1 Started (id: \(String(id.prefix(12))))\n"))
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
        let projectName = request.projectName ?? inferProjectName(from: request.composePath)
        let serviceName = request.services.first ?? ""

        guard let service = compose.services[serviceName] else {
            throw CockerError.invalidComposeFile("Service '\(serviceName)' not found")
        }

        let runConfig = try buildRunConfig(service: service, serviceName: serviceName, projectName: projectName, compose: compose, composePath: request.composePath)
        let id = try await containerEngine.run(config: runConfig)
        progressHandler(StreamEvent(stream: .status, data: "Started container \(String(id.prefix(12)))\n"))
    }

    func down(request: ComposeRequest) async throws {
        let compose = try loadComposeFile(at: request.composePath)
        let projectName = request.projectName ?? inferProjectName(from: request.composePath)

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
        if request.removeVolumes, let volumes = compose.volumes {
            for (name, volSpec) in volumes {
                let spec = volSpec ?? ComposeFile.ComposeVolumeSpec()
                if spec.external == true { continue }
                let fullName = "\(projectName)_\(name)"
                try? await containerEngine.volumes.remove(fullName)
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
            config.command = cmd.array
        }

        // env_file is the lowest-priority layer ; `environment:` overrides it.
        // Paths are relative to the compose file's directory.
        if let envFile = service.env_file {
            let baseDir = URL(fileURLWithPath: composePath).deletingLastPathComponent()
            for p in envFile.array {
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
        config.ports = (service.ports ?? []).compactMap { try? PortMapping.parse($0) }

        // Volumes
        let composeDir = (composePath as NSString).deletingLastPathComponent
        config.volumes = (service.volumes ?? []).compactMap { s in
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
