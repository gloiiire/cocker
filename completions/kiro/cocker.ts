// Fig / Kiro CLI autocomplete spec for cocker
//
// Kiro CLI (formerly Fig + Amazon Q for command line) loads this file
// to surface inline command / flag / argument suggestions in the
// terminal as the user types. See completions/kiro/README.md for the
// local install steps and the upstream-submission path.
//
// Spec discipline :
//   - Every subcommand carries a short, action-oriented `description`
//     that mirrors the help-text of the Swift CommandConfiguration.
//   - Flags use the same short/long pair the swift-argument-parser
//     accepts (e.g. -f/--force, -t/--timestamps).
//   - Container / image / network / volume / service positional args
//     pull from the live daemon via small generators below — the user
//     gets fuzzy-matchable suggestions instead of having to remember
//     IDs. The generators degrade gracefully when cockerd is down
//     (the script just returns nothing, which Fig treats as "no
//     suggestions" — never a hard error).

// ─────────────────────────────────────────────────────────────────
// Generators — query the running daemon for live suggestions
// ─────────────────────────────────────────────────────────────────

// Containers : `cocker ps -a -q` returns 12-char IDs, one per line.
// We also fetch names via a follow-up call so the user sees friendly
// labels in the popup ; the underlying argument value remains the ID
// to avoid name-collision edge cases.
const containerGenerator: Fig.Generator = {
  script: ["cocker", "ps", "-a", "--format", "json"],
  postProcess: (out) => {
    try {
      const arr = JSON.parse(out) as Array<{ id: string; name: string; image: string; status: string }>;
      return arr.map((c) => ({
        name: c.name || c.id.slice(0, 12),
        insertValue: c.name || c.id.slice(0, 12),
        description: `${c.image} · ${c.status}`,
        icon: "fig://icon?type=docker",
      }));
    } catch {
      return out
        .split("\n")
        .filter(Boolean)
        .map((id) => ({ name: id, icon: "fig://icon?type=docker" }));
    }
  },
};

// Running containers only — handy for `stop`, `kill`, `pause`, `exec`,
// `attach` where stopped containers are uninteresting.
const runningContainerGenerator: Fig.Generator = {
  script: ["cocker", "ps", "--format", "json"],
  postProcess: containerGenerator.postProcess,
};

const imageGenerator: Fig.Generator = {
  script: ["cocker", "images", "--format", "json"],
  postProcess: (out) => {
    try {
      const arr = JSON.parse(out) as Array<{ repository: string; tag: string; id: string; size: number }>;
      return arr.map((img) => {
        const ref = img.tag && img.tag !== "<none>" ? `${img.repository}:${img.tag}` : img.repository || img.id.slice(0, 12);
        return {
          name: ref,
          insertValue: ref,
          description: `${(img.size / 1024 / 1024).toFixed(1)} MB`,
          icon: "📦",
        };
      });
    } catch {
      return [];
    }
  },
};

const networkGenerator: Fig.Generator = {
  script: ["cocker", "network", "ls", "--quiet"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((n) => ({ name: n, icon: "🌐" })),
};

const volumeGenerator: Fig.Generator = {
  script: ["cocker", "volume", "ls", "--quiet"],
  postProcess: (out) => out.split("\n").filter(Boolean).map((v) => ({ name: v, icon: "💾" })),
};

const composeProjectGenerator: Fig.Generator = {
  script: ["cocker", "compose", "ls", "--format", "json"],
  postProcess: (out) => {
    try {
      const arr = JSON.parse(out) as Array<{ name: string; status: string }>;
      return arr.map((p) => ({ name: p.name, description: p.status, icon: "🧩" }));
    } catch {
      return [];
    }
  },
};

const contextGenerator: Fig.Generator = {
  script: ["cocker", "context", "ls"],
  postProcess: (out) =>
    out
      .split("\n")
      .slice(1) // skip header row
      .filter(Boolean)
      .map((line) => ({ name: line.split(/\s+/)[0], icon: "🔌" })),
};

// ─────────────────────────────────────────────────────────────────
// Shared option fragments — reused across subcommands
// ─────────────────────────────────────────────────────────────────

const forceOption: Fig.Option = {
  name: ["-f", "--force"],
  description: "Skip the confirmation / force the operation",
};

const quietOption: Fig.Option = {
  name: ["-q", "--quiet"],
  description: "Only show IDs / minimal output",
};

const noColorOption: Fig.Option = {
  name: "--no-color",
  description: "Disable ANSI color codes (also respects NO_COLOR env var)",
};

const helpOption: Fig.Option = {
  name: ["-h", "--help"],
  description: "Show help information",
};

// ─────────────────────────────────────────────────────────────────
// Top-level spec
// ─────────────────────────────────────────────────────────────────

const completion: Fig.Spec = {
  name: "cocker",
  description: "Docker-compatible container engine for Apple Silicon, powered by Apple Virtualization.framework",
  parserDirectives: {
    flagsArePosixNoncompliant: false,
  },
  subcommands: [
    // ─── Lifecycle ──────────────────────────────────────────────
    {
      name: "run",
      description: "Create and start a new container from an image",
      args: [
        { name: "image", description: "Image reference (name[:tag])", generators: imageGenerator },
        { name: "command", description: "Command to run inside the container", isOptional: true, isVariadic: true },
      ],
      options: [
        { name: ["-d", "--detach"], description: "Run in background, print container ID" },
        { name: ["-it"], description: "Allocate interactive TTY (shortcut for -i -t)" },
        { name: ["-i", "--interactive"], description: "Keep STDIN open" },
        { name: ["-t", "--tty"], description: "Allocate a pseudo-TTY" },
        { name: ["--name"], description: "Assign a name to the container", args: { name: "name" } },
        { name: ["--rm"], description: "Remove the container when it exits" },
        { name: ["-p", "--publish"], description: "Publish a port to the host", args: { name: "host:container[/proto]" }, isRepeatable: true },
        { name: ["-v", "--volume"], description: "Bind-mount a volume", args: { name: "src:dst[:opts]" }, isRepeatable: true },
        { name: ["-e", "--env"], description: "Set environment variable", args: { name: "KEY=VALUE" }, isRepeatable: true },
        { name: "--env-file", description: "Read environment from a file", args: { name: "path", template: "filepaths" } },
        { name: ["-w", "--workdir"], description: "Working directory inside the container", args: { name: "path" } },
        { name: ["-u", "--user"], description: "Username or UID", args: { name: "user[:group]" } },
        { name: "--network", description: "Connect to a network", args: { name: "name", generators: networkGenerator } },
        { name: "--restart", description: "Restart policy", args: { name: "policy", suggestions: ["no", "always", "on-failure", "unless-stopped"] } },
        { name: "--platform", description: "Platform (linux/arm64, linux/amd64)", args: { name: "platform" } },
        { name: "--cpus", description: "Number of CPUs", args: { name: "n" } },
        { name: ["-m", "--memory"], description: "Memory limit in MB", args: { name: "MB" } },
        { name: "--label", description: "Set metadata label", args: { name: "KEY=VALUE" }, isRepeatable: true },
        { name: "--healthcheck", description: "Healthcheck command", args: { name: "cmd" } },
        helpOption,
      ],
    },
    {
      name: "start",
      description: "Start one or more stopped containers",
      args: { name: "container", isVariadic: true, generators: containerGenerator },
      options: [
        { name: ["-a", "--attach"], description: "Attach STDOUT/STDERR after starting" },
        helpOption,
      ],
    },
    {
      name: "wait",
      description: "Block until one or more containers stop, then print their exit codes",
      args: { name: "container", isVariadic: true, generators: containerGenerator },
      options: [helpOption],
    },
    {
      name: "stop",
      description: "Stop one or more running containers",
      args: { name: "container", isVariadic: true, generators: runningContainerGenerator },
      options: [
        { name: "-t", description: "Seconds to wait before killing", args: { name: "seconds" } },
        helpOption,
      ],
    },
    {
      name: "kill",
      description: "Send a signal to one or more running containers",
      args: { name: "container", isVariadic: true, generators: runningContainerGenerator },
      options: [
        { name: ["-s", "--signal"], description: "Signal to send (default SIGKILL)", args: { name: "signal", suggestions: ["SIGTERM", "SIGINT", "SIGHUP", "SIGKILL", "SIGUSR1", "SIGUSR2"] } },
        helpOption,
      ],
    },
    {
      name: "restart",
      description: "Restart one or more containers",
      args: { name: "container", isVariadic: true, generators: containerGenerator },
      options: [
        { name: "-t", description: "Seconds to wait before killing", args: { name: "seconds" } },
        helpOption,
      ],
    },
    {
      name: "pause",
      description: "Pause all processes within container(s)",
      args: { name: "container", isVariadic: true, generators: runningContainerGenerator },
      options: [helpOption],
    },
    {
      name: "unpause",
      description: "Unpause paused container(s)",
      args: { name: "container", isVariadic: true, generators: containerGenerator },
      options: [helpOption],
    },
    {
      name: "rm",
      description: "Remove one or more containers",
      args: { name: "container", isVariadic: true, generators: containerGenerator },
      options: [
        forceOption,
        { name: ["-v", "--volumes"], description: "Also remove anonymous volumes" },
        helpOption,
      ],
    },
    {
      name: "rename",
      description: "Rename a container",
      args: [
        { name: "container", generators: containerGenerator },
        { name: "newName", description: "New container name" },
      ],
      options: [helpOption],
    },
    {
      name: "cp",
      description: "Copy files/folders between a container and the local filesystem",
      args: [
        { name: "source", description: "[container:]source-path" },
        { name: "destination", description: "[container:]dest-path" },
      ],
      options: [helpOption],
    },

    // ─── Logs / Exec / Attach ────────────────────────────────────
    {
      name: "logs",
      description: "Fetch container log output",
      args: { name: "container", generators: containerGenerator },
      options: [
        { name: ["-f", "--follow"], description: "Stream new log entries" },
        { name: "--tail", description: "Number of lines to show from the end (default 100)", args: { name: "N" } },
        { name: ["-t", "--timestamps"], description: "Show RFC3339 timestamps" },
        { name: "--since", description: "Show entries after this RFC3339 timestamp", args: { name: "timestamp" } },
        helpOption,
      ],
    },
    {
      name: "exec",
      description: "Run a command inside a running container",
      args: [
        { name: "container", generators: runningContainerGenerator },
        { name: "command", isVariadic: true },
      ],
      options: [
        { name: ["-i", "--interactive"], description: "Keep STDIN open" },
        { name: "-t", description: "Allocate a pseudo-TTY" },
        { name: ["-u"], description: "Username or UID", args: { name: "user[:group]" } },
        { name: ["-w", "--workdir"], description: "Working directory", args: { name: "path" } },
        { name: ["-e", "--env"], description: "Environment variable", args: { name: "KEY=VALUE" }, isRepeatable: true },
        helpOption,
      ],
    },
    {
      name: "attach",
      description: "Attach local STDIN/STDOUT/STDERR to a running container",
      args: { name: "container", generators: runningContainerGenerator },
      options: [
        { name: "--no-stdin", description: "Do not attach STDIN" },
        helpOption,
      ],
    },

    // ─── PS family ──────────────────────────────────────────────
    {
      name: "ps",
      description: "List containers",
      options: [
        { name: ["-a", "--all"], description: "Show all containers (default : running only)" },
        quietOption,
        { name: "--filter", description: "Filter expression (key=value)", args: { name: "filter" }, isRepeatable: true },
        { name: "--format", description: "Format output (table | json)", args: { name: "fmt", suggestions: ["table", "json"] } },
        { name: "--json", description: "JSON output (alias of --format=json)" },
        helpOption,
      ],
    },
    {
      name: "inspect",
      description: "Display detailed JSON info for one or more containers",
      args: { name: "container", isVariadic: true, generators: containerGenerator },
      options: [helpOption],
    },
    {
      name: "stats",
      description: "Live CPU / memory stats stream",
      args: { name: "container", isVariadic: true, isOptional: true, generators: containerGenerator },
      options: [
        { name: "--no-stream", description: "Print a single snapshot and exit" },
        { name: ["-a", "--all"], description: "Show all containers (not only running)" },
        helpOption,
      ],
    },
    {
      name: "top",
      description: "Show running processes inside a container",
      args: { name: "container", generators: runningContainerGenerator },
      options: [helpOption],
    },
    {
      name: "port",
      description: "List port mappings for a container",
      args: [
        { name: "container", generators: containerGenerator },
        { name: "port", isOptional: true, description: "Filter to one container port" },
      ],
      options: [helpOption],
    },
    {
      name: "diff",
      description: "List filesystem changes in a container's writable layer",
      args: { name: "container", generators: containerGenerator },
      options: [helpOption],
    },

    // ─── Images ─────────────────────────────────────────────────
    {
      name: "images",
      description: "List images",
      args: { name: "repository", isOptional: true },
      options: [
        { name: ["-a", "--all"], description: "Show intermediate images" },
        quietOption,
        helpOption,
      ],
    },
    {
      name: "image",
      description: "Manage images",
      subcommands: [
        { name: "ls", description: "List images" },
        { name: "build", description: "Build an image from a Dockerfile" },
        { name: "rmi", description: "Remove one or more images" },
        { name: "tag", description: "Create a tag that points at SOURCE_IMAGE" },
        { name: "inspect", description: "Display detailed JSON for one or more images", args: { name: "image", isVariadic: true, generators: imageGenerator } },
        { name: "history", description: "Show the layer history of an image" },
        { name: "prune", description: "Remove unused images" },
      ],
      options: [helpOption],
    },
    {
      name: "pull",
      description: "Pull an image from a registry",
      args: { name: "image", description: "Image reference (name[:tag][@digest])" },
      options: [
        { name: "--platform", description: "Target platform (linux/arm64, linux/amd64)", args: { name: "platform" } },
        helpOption,
      ],
    },
    {
      name: "push",
      description: "Push an image to a registry",
      args: { name: "image", generators: imageGenerator },
      options: [helpOption],
    },
    {
      name: "rmi",
      description: "Remove one or more images",
      args: { name: "image", isVariadic: true, generators: imageGenerator },
      options: [forceOption, helpOption],
    },
    {
      name: "tag",
      description: "Create a tag TARGET_IMAGE that refers to SOURCE_IMAGE",
      args: [
        { name: "source", generators: imageGenerator },
        { name: "target", description: "name:tag" },
      ],
      options: [helpOption],
    },
    {
      name: "build",
      description: "Build an image from a Dockerfile",
      args: { name: "context", description: "Build context path (default : .)", isOptional: true, template: "folders" },
      options: [
        { name: ["-t", "--tag"], description: "Name and optionally a tag (name:tag)", args: { name: "name:tag" }, isRepeatable: true },
        { name: ["-f", "--file"], description: "Dockerfile path (default : Dockerfile)", args: { name: "path", template: "filepaths" } },
        { name: "--build-arg", description: "Build-time variable", args: { name: "KEY=VALUE" }, isRepeatable: true },
        { name: "--no-cache", description: "Do not use cache when building" },
        { name: "--target", description: "Set the target build stage", args: { name: "stage" } },
        { name: "--platform", description: "Target platform", args: { name: "platform" } },
        helpOption,
      ],
    },
    {
      name: "save",
      description: "Save one or more images to a tar archive",
      args: { name: "image", generators: imageGenerator },
      options: [
        { name: ["-o", "--output"], description: "Output file (defaults to stdout)", args: { name: "path", template: "filepaths" } },
        helpOption,
      ],
    },
    {
      name: "load",
      description: "Load an image from a tar archive",
      options: [
        { name: ["-i", "--input"], description: "Input tar file", args: { name: "path", template: "filepaths" } },
        helpOption,
      ],
    },
    {
      name: "history",
      description: "Show the layer history of an image",
      args: { name: "image", generators: imageGenerator },
      options: [quietOption, helpOption],
    },
    {
      name: "commit",
      description: "Create a new image from a container's changes",
      args: [
        { name: "container", generators: containerGenerator },
        { name: "repository", description: "name[:tag]" },
      ],
      options: [
        { name: ["-a", "--author"], description: "Author (e.g. \"Alice <alice@example.com>\")", args: { name: "author" } },
        { name: ["-m", "--message"], description: "Commit message", args: { name: "msg" } },
        helpOption,
      ],
    },
    {
      name: "export",
      description: "Export a container's filesystem as a tar archive",
      args: { name: "container", generators: containerGenerator },
      options: [
        { name: ["-o", "--output"], description: "Output file (defaults to stdout)", args: { name: "path", template: "filepaths" } },
        helpOption,
      ],
    },
    {
      name: "import",
      description: "Import a tarball as an image",
      args: [
        { name: "file", description: "Path to tar file (- for stdin)", template: "filepaths" },
        { name: "tag", description: "image:tag" },
      ],
      options: [helpOption],
    },
    {
      name: "update",
      description: "Update configuration of one or more containers",
      args: { name: "container", isVariadic: true, generators: containerGenerator },
      options: [
        { name: "--cpus", description: "Number of CPUs", args: { name: "n" } },
        { name: ["-m"], description: "Memory limit in MB", args: { name: "MB" } },
        helpOption,
      ],
    },

    // ─── Container subcommand (prune) ────────────────────────────
    {
      name: "container",
      description: "Manage containers",
      subcommands: [
        { name: "prune", description: "Remove all stopped containers", options: [forceOption, helpOption] },
      ],
      options: [helpOption],
    },

    // ─── Networks ────────────────────────────────────────────────
    {
      name: "network",
      description: "Manage networks",
      subcommands: [
        {
          name: "ls",
          description: "List networks",
          options: [quietOption, helpOption],
        },
        {
          name: "create",
          description: "Create a network",
          args: { name: "name" },
          options: [
            { name: ["-d"], description: "Driver (bridge|host|none|overlay)", args: { name: "driver", suggestions: ["bridge", "host", "none", "overlay"] } },
            { name: "--subnet", description: "Not implemented: refused (exit 126)", args: { name: "cidr" } },
            { name: "--gateway", description: "Not implemented: refused (exit 126)", args: { name: "ip" } },
            { name: "--label", description: "Metadata label", args: { name: "KEY=VALUE" }, isRepeatable: true },
            helpOption,
          ],
        },
        {
          name: "rm",
          description: "Remove one or more networks",
          args: { name: "network", isVariadic: true, generators: networkGenerator },
          options: [helpOption],
        },
        {
          name: "inspect",
          description: "Display detailed JSON for one or more networks",
          args: { name: "network", isVariadic: true, generators: networkGenerator },
          options: [helpOption],
        },
        {
          name: "connect",
          description: "Attach a container to a network",
          args: [
            { name: "network", generators: networkGenerator },
            { name: "container", generators: containerGenerator },
          ],
          options: [helpOption],
        },
        {
          name: "disconnect",
          description: "Detach a container from a network",
          args: [
            { name: "network", generators: networkGenerator },
            { name: "container", generators: containerGenerator },
          ],
          options: [forceOption, helpOption],
        },
      ],
      options: [helpOption],
    },

    // ─── Volumes ─────────────────────────────────────────────────
    {
      name: "volume",
      description: "Manage volumes",
      subcommands: [
        { name: "ls", description: "List volumes", options: [quietOption, helpOption] },
        {
          name: "create",
          description: "Create a volume",
          args: { name: "name", isOptional: true },
          options: [
            { name: ["-d", "--driver"], description: "Volume driver", args: { name: "driver" } },
            { name: "--label", description: "Metadata label", args: { name: "KEY=VALUE" }, isRepeatable: true },
            helpOption,
          ],
        },
        { name: "rm", description: "Remove one or more volumes", args: { name: "volume", isVariadic: true, generators: volumeGenerator }, options: [forceOption, helpOption] },
        { name: "inspect", description: "Display detailed JSON for one or more volumes", args: { name: "volume", isVariadic: true, generators: volumeGenerator }, options: [helpOption] },
        { name: "prune", description: "Remove all unused local volumes", options: [forceOption, helpOption] },
      ],
      options: [helpOption],
    },

    // ─── Compose ─────────────────────────────────────────────────
    {
      name: "compose",
      description: "Define and run multi-container applications",
      subcommands: [
        {
          name: "up",
          description: "Create and start the services in a project",
          args: { name: "service", isVariadic: true, isOptional: true },
          options: [
            { name: ["-d", "--detach"], description: "Run in background" },
            { name: ["-f", "--file"], description: "Compose file path (default : cocker-compose.yml)", args: { name: "path", template: "filepaths" } },
            { name: ["-p", "--project-name"], description: "Project name override", args: { name: "name" } },
            { name: "--build", description: "Build images before starting" },
            { name: "--remove-orphans", description: "Remove containers not in compose file" },
            helpOption,
          ],
        },
        {
          name: "down",
          description: "Stop and remove containers, networks",
          options: [
            { name: ["-f", "--file"], description: "Compose file path", args: { name: "path", template: "filepaths" } },
            { name: ["-p", "--project-name"], description: "Project name", args: { name: "name" } },
            { name: ["-v", "--volumes"], description: "Also remove named volumes" },
            { name: "--remove-orphans", description: "Remove orphaned containers" },
            helpOption,
          ],
        },
        { name: "ls", description: "List running compose projects", options: [helpOption] },
        {
          name: "logs",
          description: "View output from containers",
          args: { name: "service", isVariadic: true, isOptional: true },
          options: [
            { name: ["-f", "--follow"], description: "Follow log output" },
            { name: "--tail", description: "Lines from end (default 100)", args: { name: "N" } },
            { name: ["-t", "--timestamps"], description: "Show timestamps" },
            helpOption,
          ],
        },
        { name: "ps", description: "List containers in the project", options: [helpOption] },
        {
          name: "exec",
          description: "Run a command in a running service container",
          args: [
            { name: "service" },
            { name: "command", isVariadic: true },
          ],
          options: [
            { name: "--no-tty", description: "Do not allocate a TTY" },
            helpOption,
          ],
        },
        {
          name: "run",
          description: "Run a one-off command in a fresh service container",
          args: [
            { name: "service" },
            { name: "command", isVariadic: true },
          ],
          options: [helpOption],
        },
        { name: "build", description: "Build/rebuild services", args: { name: "service", isVariadic: true, isOptional: true }, options: [helpOption] },
        { name: "pull", description: "Pull images for services", args: { name: "service", isVariadic: true, isOptional: true }, options: [helpOption] },
        { name: "restart", description: "Restart services", args: { name: "service", isVariadic: true, isOptional: true }, options: [helpOption] },
        { name: "pause", description: "Pause services", args: { name: "service", isVariadic: true, isOptional: true }, options: [helpOption] },
        { name: "unpause", description: "Unpause services", args: { name: "service", isVariadic: true, isOptional: true }, options: [helpOption] },
        { name: "kill", description: "Force-stop service containers", args: { name: "service", isVariadic: true, isOptional: true }, options: [helpOption] },
        { name: "top", description: "Show running processes in service", args: { name: "service" }, options: [helpOption] },
        { name: "port", description: "Print public port for a service binding", args: [{ name: "service" }, { name: "port" }], options: [helpOption] },
        { name: "images", description: "List images used by services", options: [helpOption] },
        { name: "events", description: "Stream events from containers", options: [helpOption] },
        { name: "config", description: "Validate and view the compose file (YAML or JSON)", options: [helpOption] },
        {
          name: "watch",
          description: "Watch the project for changes and rebuild on save",
          options: [
            { name: ["-d", "--detach"], description: "Run watch loop in background" },
            { name: "--stop", description: "Stop the running watch loop" },
            { name: "--status", description: "Show the watch loop's status" },
            { name: "--logs", description: "Tail the watch loop's log" },
            { name: "--debounce", description: "FSEvents debounce in milliseconds (default 300)", args: { name: "ms" } },
            helpOption,
          ],
        },
      ],
      options: [helpOption],
    },

    // ─── Daemon ──────────────────────────────────────────────────
    {
      name: "daemon",
      description: "Manage the background cockerd process",
      subcommands: [
        {
          name: "start",
          description: "Start cockerd in the background",
          options: [
            { name: "--binary", description: "Explicit path to cockerd", args: { name: "path", template: "filepaths" } },
            { name: "--foreground", description: "Run in the foreground (Ctrl-C to stop)" },
            { name: ["-s", "--service"], description: "Use launchd / brew services backend" },
            helpOption,
          ],
        },
        {
          name: "stop",
          description: "Stop the background cockerd process",
          options: [
            { name: "--timeout", description: "Seconds before SIGKILL (default 10)", args: { name: "seconds" } },
            { name: ["-s", "--service"], description: "Bootout the launchd job / `brew services stop` so no respawn" },
            helpOption,
          ],
        },
        {
          name: "restart",
          description: "Stop then start cockerd",
          options: [
            { name: "--binary", description: "Explicit path to cockerd", args: { name: "path", template: "filepaths" } },
            { name: ["-s", "--service"], description: "Restart via launchd / brew services" },
            helpOption,
          ],
        },
        { name: "status", description: "Show whether cockerd is running", options: [helpOption] },
        {
          name: "logs",
          description: "Tail cockerd's log",
          options: [
            { name: ["-f", "--follow"], description: "Follow new lines" },
            { name: "--tail", description: "Last N lines (default 50)", args: { name: "N" } },
            noColorOption,
            helpOption,
          ],
        },
        { name: "clear-leases", description: "Truncate macOS vmnet's DHCP lease file", options: [helpOption] },
        { name: "helper-install", description: "Install the lease-clearing LaunchDaemon (one-time sudo)", options: [helpOption] },
        {
          name: "tls-init",
          description: "Generate self-signed mTLS certs for remote docker.sock",
          options: [
            { name: "--cn", description: "CA Common Name (default cocker-ca)", args: { name: "cn" } },
            { name: "--host", description: "Hostname / IP the cert validates (default localhost)", args: { name: "host" } },
            { name: "--days", description: "Validity in days (default 365)", args: { name: "n" } },
            { name: "--force", description: "Overwrite existing certs" },
            helpOption,
          ],
        },
        { name: "resign", description: "Re-sign cockerd with your Apple Development cert", options: [helpOption] },
        { name: "setup", description: "Refresh ~/.cocker/kernel/ (symlink kernel + copy initrd)", options: [helpOption] },
        { name: "init", description: "One-command post-install : resign + setup + start", options: [{ name: "--dry-run", description: "Print what would happen without changing anything" }, noColorOption, helpOption] },
      ],
      options: [helpOption],
    },

    // ─── System / version / info ─────────────────────────────────
    {
      name: "version",
      description: "Show client + daemon version info",
      options: [
        { name: "--json", description: "Emit JSON" },
        helpOption,
      ],
    },
    { name: "info", description: "Display system-wide information", options: [helpOption] },
    {
      name: "system",
      description: "Manage cocker",
      subcommands: [
        { name: "prune", description: "Remove unused data (stopped containers, dangling images)", options: [forceOption, { name: ["--volumes"], description: "Also prune volumes" }, helpOption] },
        { name: "info", description: "Display system-wide info", options: [helpOption] },
        {
          name: "events",
          description: "Get real-time daemon events",
          options: [
            { name: "--since", description: "Show events since timestamp", args: { name: "timestamp" } },
            { name: "--filter", description: "Filter expression (event=, type=, container=)", args: { name: "filter" }, isRepeatable: true },
            helpOption,
          ],
        },
        { name: "df", description: "Show disk usage summary", options: [helpOption] },
      ],
      options: [helpOption],
    },

    // ─── Auth ────────────────────────────────────────────────────
    {
      name: "login",
      description: "Log in to a container registry",
      args: { name: "server", isOptional: true, description: "Registry hostname (default : registry-1.docker.io)" },
      options: [
        { name: ["-u", "--username"], description: "Username", args: { name: "user" } },
        { name: ["-p", "--password"], description: "Password (prefer --password-stdin)", args: { name: "password" } },
        { name: "--password-stdin", description: "Take the password from stdin" },
        helpOption,
      ],
    },
    {
      name: "logout",
      description: "Log out from a container registry",
      args: { name: "server", isOptional: true },
      options: [helpOption],
    },

    // ─── Context ────────────────────────────────────────────────
    {
      name: "context",
      description: "Manage daemon connection contexts",
      subcommands: [
        { name: "ls", description: "List contexts", options: [helpOption] },
        {
          name: "create",
          description: "Create a context",
          args: { name: "name" },
          options: [
            { name: "--description", description: "Free-text description", args: { name: "text" } },
            { name: "--docker", description: "Docker endpoint (host=unix:///path/to/socket)", args: { name: "endpoint" } },
            helpOption,
          ],
        },
        { name: "use", description: "Set the current context", args: { name: "name", generators: contextGenerator }, options: [helpOption] },
        { name: "rm", description: "Remove one or more contexts", args: { name: "name", isVariadic: true, generators: contextGenerator }, options: [helpOption] },
        { name: "inspect", description: "Display detailed JSON for one or more contexts", args: { name: "name", isVariadic: true, isOptional: true, generators: contextGenerator }, options: [helpOption] },
        { name: "show", description: "Print the current context's name", options: [helpOption] },
      ],
      options: [helpOption],
    },

    // ─── Secrets / Configs ───────────────────────────────────────
    {
      name: "secret",
      description: "Manage cocker secrets (host-side opaque blobs)",
      subcommands: [
        { name: "create", description: "Create a secret from a file or STDIN", args: [{ name: "name" }, { name: "file", template: "filepaths" }], options: [helpOption] },
        { name: "ls", description: "List secrets", options: [helpOption] },
        { name: "rm", description: "Remove one or more secrets", args: { name: "name", isVariadic: true }, options: [helpOption] },
        { name: "inspect", description: "Display detailed info for one or more secrets", args: { name: "name", isVariadic: true }, options: [helpOption] },
      ],
      options: [helpOption],
    },
    {
      name: "config",
      description: "Manage cocker configs (host-side non-sensitive blobs)",
      subcommands: [
        { name: "create", description: "Create a config from a file or STDIN", args: [{ name: "name" }, { name: "file", template: "filepaths" }], options: [helpOption] },
        { name: "ls", description: "List configs", options: [helpOption] },
        { name: "rm", description: "Remove one or more configs", args: { name: "name", isVariadic: true }, options: [helpOption] },
        { name: "inspect", description: "Display detailed info for one or more configs", args: { name: "name", isVariadic: true }, options: [helpOption] },
      ],
      options: [helpOption],
    },

    // ─── Plugins ─────────────────────────────────────────────────
    {
      name: "plugin",
      description: "Manage plugins (stub : registered but not executed)",
      subcommands: [
        { name: "install", description: "Install a plugin", args: { name: "ref" }, options: [{ name: "--disable", description: "Install but do not enable" }, helpOption] },
        { name: "ls", description: "List plugins", options: [helpOption] },
        { name: "rm", description: "Remove plugins", args: { name: "name", isVariadic: true }, options: [helpOption] },
        { name: "enable", description: "Enable a plugin", args: { name: "name" }, options: [helpOption] },
        { name: "disable", description: "Disable a plugin", args: { name: "name" }, options: [helpOption] },
        { name: "inspect", description: "Display detailed info for one or more plugins", args: { name: "name", isVariadic: true }, options: [helpOption] },
      ],
      options: [helpOption],
    },

    // ─── Buildx ──────────────────────────────────────────────────
    {
      name: "buildx",
      description: "Multi-platform build helper",
      subcommands: [
        { name: "build", description: "Multi-platform build (alias of `cocker build`)", args: { name: "context", isOptional: true, template: "folders" }, options: [helpOption] },
        { name: "ls", description: "List builders", options: [helpOption] },
        { name: "create", description: "Create a builder", args: { name: "name", isOptional: true }, options: [helpOption] },
        { name: "use", description: "Set the current builder", args: { name: "name" }, options: [helpOption] },
        { name: "rm", description: "Remove builders", args: { name: "name", isVariadic: true }, options: [helpOption] },
        {
          name: "install-qemu",
          description: "Install qemu-user-static binaries for cross-arch builds",
          options: [
            { name: "--arch", description: "Target architecture", args: { name: "arch", suggestions: ["amd64", "arm64", "arm", "ppc64le", "s390x"] }, isRepeatable: true },
            { name: "--all", description: "Install all supported architectures" },
            { name: "--force", description: "Reinstall even if present" },
            helpOption,
          ],
        },
      ],
      options: [helpOption],
    },

    // ─── Swarm / Stack / Node / Service (single-node) ────────────
    {
      name: "swarm",
      description: "Manage swarm (single-node mode)",
      subcommands: [
        { name: "init", description: "Initialize a swarm", options: [{ name: "--advertise-addr", description: "Advertised address", args: { name: "addr" } }, helpOption] },
        { name: "leave", description: "Leave the swarm", options: [forceOption, helpOption] },
        { name: "join", description: "Join a swarm (single-node no-op)", args: { name: "addr" }, options: [{ name: "--token", description: "Join token", args: { name: "token" } }, helpOption] },
      ],
      options: [helpOption],
    },
    {
      name: "stack",
      description: "Manage stacks (compose-backed)",
      subcommands: [
        { name: "deploy", description: "Deploy or update a stack", args: { name: "name" }, options: [{ name: ["-c", "--compose-file"], description: "Compose file path", args: { name: "path", template: "filepaths" } }, { name: "--with-registry-auth", description: "Send registry auth to agents" }, helpOption] },
        { name: "ls", description: "List stacks", options: [helpOption] },
        { name: "rm", description: "Remove stacks", args: { name: "name", isVariadic: true }, options: [helpOption] },
        { name: "services", description: "List services in a stack", args: { name: "name" }, options: [helpOption] },
        { name: "ps", description: "List tasks in a stack", args: { name: "name" }, options: [helpOption] },
      ],
      options: [helpOption],
    },
    {
      name: "node",
      description: "Manage swarm nodes (single-node mode)",
      subcommands: [
        { name: "ls", description: "List nodes", options: [helpOption] },
        { name: "inspect", description: "Display detailed JSON for one or more nodes", args: { name: "name", isVariadic: true }, options: [helpOption] },
      ],
      options: [helpOption],
    },
    {
      name: "service",
      description: "Manage services",
      subcommands: [
        { name: "ls", description: "List services", options: [helpOption] },
        { name: "ps", description: "List tasks of one or more services", args: { name: "name", isVariadic: true }, options: [helpOption] },
        { name: "inspect", description: "Display detailed JSON for one or more services", args: { name: "name", isVariadic: true }, options: [helpOption] },
        {
          name: "create",
          description: "Create a service",
          args: [
            { name: "image", generators: imageGenerator },
            { name: "command", isVariadic: true, isOptional: true },
          ],
          options: [
            { name: "--name", description: "Service name", args: { name: "name" } },
            { name: ["-p", "--publish"], description: "Publish a port", args: { name: "spec" }, isRepeatable: true },
            { name: ["-e", "--env"], description: "Environment variable", args: { name: "KEY=VALUE" }, isRepeatable: true },
            { name: "--replicas", description: "Number of replicas (single-node ignores >1)", args: { name: "n" } },
            { name: "--network", description: "Network to attach", args: { name: "name", generators: networkGenerator } },
            { name: "--mount", description: "Mount a volume", args: { name: "spec" }, isRepeatable: true },
            { name: "--constraint", description: "Placement constraint", args: { name: "spec" }, isRepeatable: true },
            helpOption,
          ],
        },
        { name: "rm", description: "Remove services", args: { name: "name", isVariadic: true }, options: [helpOption] },
        { name: "update", description: "Update a service", args: { name: "name" }, options: [{ name: "--image", description: "New image", args: { name: "image" } }, { name: "--replicas", description: "Replicas", args: { name: "n" } }, helpOption] },
        { name: "scale", description: "Scale services", args: { name: "spec", description: "service=replicas", isVariadic: true }, options: [helpOption] },
      ],
      options: [helpOption],
    },

    // ─── iCloud ─────────────────────────────────────────────────
    {
      name: "icloud",
      description: "Inspect & control iCloud-aware behavior",
      subcommands: [
        { name: "status", description: "Show iCloud materialization state for a path", args: { name: "path", isOptional: true, template: "folders" }, options: [{ name: "--json", description: "Emit JSON" }, helpOption] },
        { name: "prefetch", description: "Force-materialize files under a path", args: { name: "path", template: "folders" }, options: [helpOption] },
        { name: "cache-clear", description: "Clear the local iCloud staging cache", options: [helpOption] },
      ],
      options: [helpOption],
    },

    // ─── Shell completion (bash/zsh/fish) ──────────────────────
    {
      name: ["shell-completion", "completion"],
      description: "Generate native bash/zsh/fish completion script",
      args: { name: "shell", suggestions: ["bash", "zsh", "fish"] },
      options: [helpOption],
    },

    // ─── Autocomplete (this very spec's installer) ──────────────
    {
      name: "autocomplete",
      description: "Install / inspect rich autocomplete specs (Kiro CLI, Fig)",
      subcommands: [
        {
          name: "install",
          description: "Copy the Kiro/Fig autocomplete spec into ~/.fig/autocomplete/build/",
          options: [
            { name: "--source", description: "Explicit path to cocker.ts / cocker.js", args: { name: "path", template: "filepaths" } },
            { name: "--dry-run", description: "Print what would happen without modifying anything" },
            helpOption,
          ],
        },
        {
          name: "status",
          description: "Show where cocker's autocomplete spec is installed (if at all)",
          options: [helpOption],
        },
      ],
      options: [helpOption],
    },
  ],
  options: [
    { name: "--version", description: "Show the cocker version" },
    noColorOption,
    helpOption,
  ],
};

export default completion;
