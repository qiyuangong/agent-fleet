# scripts/ — Setup & Fleet Launch Entry Points

| Script | Purpose |
| --- | --- |
| `setup.sh` | One-shot environment bootstrap: installs Node + Claude Code, writes config, installs skills |
| `run_fleet.sh` | Routes tasksets to the existing Harbor or OpenClaw runner |
| `dind-run.sh` | Start/reuse a Docker-in-Docker runner, bootstrap it, then invoke `run_fleet.sh` |

For the end-to-end quick start, see the [root README](../README.md#quick-start).

---

## setup.sh

### Usage

```bash
./scripts/setup.sh
# Interactive prompt for BASE_URL / API_KEY / MODEL
```

Or pre-fill via env vars (suitable for automation):

```bash
BASE_URL=https://your-model-gateway.example.com \
API_KEY=your-token \
MODEL=glm-5.1-fp8 \
./scripts/setup.sh
```

**Prerequisites**: Manually install `git` / `curl` / `jq` / `docker` / `python3`. Node and Claude Code do not need to be pre-installed.

### Details

<details>
<summary>What setup.sh does</summary>

1. Gather model endpoint config (interactive prompt or env vars)
2. Check base dependencies (git / curl / docker / python3)
3. Install Node.js via nvm (if missing or < 18)
4. Install Claude Code (pinned to 2.1.90)
5. Write env vars to `~/.bashrc`
6. Clone the repo + install the skills plugin
7. Write `config.local.env`
8. Check Docker permissions

</details>

<details>
<summary>Idempotency notes</summary>

- `~/.bashrc`: wrapped in a marker block `# >>> sii-agent-fleet env >>>`, the whole block is replaced each run
- `~/.claude/settings.json`: managed keys are merged, user customizations preserved
- `config.local.env`: only managed keys are updated, comments and other keys are preserved
- A backup is taken before each modification (`*.bak.sii-agent-fleet`)

Safe to re-run.

</details>

---

## run_fleet.sh

### Direct taskset runs

```bash
./scripts/run_fleet.sh --taskset <taskset> [--agent <agent>] [--workers <n>] [--detach] [--dry-run]
./scripts/run_fleet.sh --spec <file|-> [--detach] [--dry-run]
```

| Option | Description |
| --- | --- |
| `--taskset <value>` | Harbor taskset, explicit local path, `pinchbench`, or `clawbio` |
| `--agent <name>` | Optional Harbor agent override; `openclaw` is accepted for consistent OpenClaw commands |
| `--workers <n>` | Harbor workers or OpenClaw fleet instances |
| `--spec <file|->` | Read a FleetSpec v1 JSON object from a file or standard input |
| `--detach` | Start Harbor in its detached Zellij mode; ignored with a warning for OpenClaw tasksets |
| `--dry-run` | Print the downstream command and environment without running it |

Examples:

```bash
./scripts/run_fleet.sh --taskset terminal-bench/terminal-bench-2-1 \
  --agent claude-code --workers 10 --detach
./scripts/run_fleet.sh --taskset ./my-taskset --agent opencode --workers 2
./scripts/run_fleet.sh --taskset pinchbench --agent openclaw --workers 10
./scripts/run_fleet.sh --taskset clawbio --agent openclaw --workers 10
./scripts/run_fleet.sh --taskset terminal-bench/terminal-bench-2-1 \
  --agent claude-code --workers 10 --dry-run
```

### FleetSpec JSON

Create `fleet-spec.json` with any text editor, for example
`nano fleet-spec.json`, and enter:

```json
{
  "schema_version": 1,
  "taskset": "terminal-bench/terminal-bench-2",
  "agent": "opencode",
  "workers": 4
}
```

| Field | Required | Value |
| --- | --- | --- |
| `schema_version` | Yes | Must be `1` |
| `taskset` | Yes | Registry ID, explicit local path, `pinchbench`, or `clawbio` |
| `agent` | No | Agent passed to the selected runner |
| `workers` | No | Integer from 1 to 4096 |

Preview the resolved command, then run it:

```bash
./scripts/run_fleet.sh --spec ./fleet-spec.json --dry-run
./scripts/run_fleet.sh --spec ./fleet-spec.json
```

Automation can generate the same file without string interpolation:

```bash
jq -n \
  --arg taskset "terminal-bench/terminal-bench-2" \
  --arg agent "claude-code" \
  --argjson workers 2 \
  '{schema_version: 1, taskset: $taskset, agent: $agent, workers: $workers}' \
  > fleet-spec.json
```

To run without creating a file, pass one JSON object on standard input:

```bash
./scripts/run_fleet.sh --spec - --dry-run <<'JSON'
{
  "schema_version": 1,
  "taskset": "pinchbench",
  "workers": 2
}
JSON
```

Spec input cannot be combined with `--taskset`, `--agent`, or `--workers`.
Multiple JSON values, unknown fields, control characters, and invalid values
are rejected.

`run_fleet.sh` only parses these options, maps them to the selected
runner, and replaces itself with that runner. It does not generate run IDs,
create output directories, create or monitor sessions, filter tasks, run
preflight checks, or translate downstream errors.

Harbor tasksets call `Agents/utils/common/Harbor/start.sh`. Local tasksets must
use an explicit path beginning with `./`, `../`, `/`, or `~/`. Harbor owns its
configuration, taskset and agent validation, scheduling, Zellij lifecycle,
tracing, run IDs, outputs, and failures. `--detach` is passed directly to
Harbor's existing Zellij launcher.

The `pinchbench` taskset calls the existing PinchBench parallel
runner and maps workers to `--instances`; the OpenClaw fleet must already be
configured and running. The `clawbio` taskset calls the existing
ClawBio unified launcher and maps workers to `COUNT`. Those runners own setup,
validation, execution, outputs, and failures. If `--agent` conflicts with an
OpenClaw taskset, the router prints the requested and actual agents, ignores the
conflicting value, and continues with OpenClaw. OpenClaw runners remain in the
foreground; `--detach` is ignored with a warning.

---

## dind-run.sh

This internal launcher lets benchmark Docker pulls and builds use a nested
daemon's registry mirrors without changing the host Docker daemon.

### Usage

```bash
# config.env already sets CN Docker Hub mirrors; override in config.local.env if needed:
DIND_REGISTRY_MIRRORS=https://docker.m.daocloud.io,https://mirror.ccs.tencentyun.com

./scripts/dind-run.sh --taskset terminalbench21 --agent claude-code --workers 1
```

`DIND_REGISTRY_MIRRORS` is comma-separated. If you include spaces after
commas in an env file, quote the value:

```bash
DIND_REGISTRY_MIRRORS="https://docker.m.daocloud.io, https://mirror.ccs.tencentyun.com"
```

When invoked inside a container, the launcher warns and delegates directly to
`scripts/run_fleet.sh` instead of starting another DinD container.

### Details

<details>
<summary>Run flow</summary>

1. Load `config.env` → `config.local.env` → restore caller env.
2. Build the local `sii-agent-fleet-dind:28` image if missing.
3. Start or reuse a privileged container from that image.
4. Pass each mirror and default address pool as Docker daemon flags.
5. Mount the repo at the same absolute path inside DinD.
6. Forward configured HTTP(S) proxy settings and a no-proxy list that includes
   the model and Opik hosts.
7. Run `scripts/setup.sh` inside DinD unless `DIND_BOOTSTRAP=skip`.
8. Run `scripts/run_fleet.sh` inside DinD with the same arguments.

</details>

### Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `DIND_REGISTRY_MIRRORS` | `https://docker.m.daocloud.io,https://mirror.ccs.tencentyun.com` from `config.env` | Comma-separated registry mirror URLs for the nested Docker daemon |
| `DIND_REGISTRY_MIRROR` | _(empty)_ | Singular fallback used only when `DIND_REGISTRY_MIRRORS` is unset |
| `DIND_DEFAULT_ADDRESS_POOLS` | `base=10.200.0.0/13,size=21` from `config.env` | Semicolon-separated Docker daemon default-address-pool specs for nested bridge networks |
| `DIND_NAME` | `sii-agent-fleet-dind` | DinD container name |
| `DIND_IMAGE` | `sii-agent-fleet-dind:28` | Prepared DinD runner image; the default is built locally if missing |
| `DIND_IMAGE_DOCKERFILE` | `scripts/dind/Dockerfile` | Dockerfile used to build the default DinD runner image |
| `DIND_BASE_IMAGE` | `m.daocloud.io/docker.io/library/docker:28-dind` | Base image used when building the default image |
| `DIND_DOCKER_VOLUME` | `<DIND_NAME>-docker` | Persistent `/var/lib/docker` volume for nested image/build cache reuse |
| `DIND_HOME_VOLUME` | `<DIND_NAME>-home` | Persistent benchmark-user home volume for Claude/plugin setup |
| `DIND_USER` | `sii` | Unprivileged user that runs `run_fleet.sh`; must exist in `DIND_IMAGE` |
| `DIND_HOME_DIR` | `/home/<DIND_USER>` | Home path mounted from `DIND_HOME_VOLUME` |
| `DIND_USER_UID` / `DIND_USER_GID` | caller's UID / GID | IDs assigned to `DIND_USER` so the mounted checkout stays writable without host-side `chown` |
| `DIND_PORTS` | _(empty)_ | Comma-separated `docker run -p` entries, e.g. `18789-18989:18789-18989` |
| `DIND_MOUNTS` | _(empty)_ | Comma-separated extra `docker run -v` entries for datasets/caches |
| `DIND_BOOTSTRAP` | `missing` | `always`, `missing`, or `skip` for `scripts/setup.sh` |
| `DIND_TTY` | `auto` | `auto` adds `-it` when stdin/stdout are terminals; set `1` or `0` to force |
| `DIND_RESET` | `0` | Set `1` to remove the DinD container and Docker storage volume first |

### Caveats

- Requires privileged Docker on the host.
- The launcher runs as the image's unprivileged `sii` user so Claude Code can
  use bypass-permissions mode. Setup installs global packages as root, then
  transfers the benchmark home directory to that user. The wrapper maps that
  user's UID/GID to the calling host user so it can write result files to the
  mounted checkout without changing host file ownership.
- The default image extends the Docker official DinD image via the DaoCloud
  prefix and bakes in the README Step 0 launch prerequisites. It is not rebuilt
  automatically after Dockerfile edits; remove `sii-agent-fleet-dind:28` to
  force a rebuild, and use `DIND_RESET=1` if an existing DinD container should
  be recreated from the rebuilt image.
- Does not mount `/var/run/docker.sock`; nested containers use DinD storage.
- DinD keeps a separate Docker image/build cache, so first runs may be slower
  and use more disk than host Docker. The default persistent
  `DIND_DOCKER_VOLUME` keeps `/var/lib/docker` across runs to mitigate repeat
  pull/build cost.
- DinD uses `DIND_DEFAULT_ADDRESS_POOLS` for nested bridge networks. Docker's
  `size` value is a CIDR prefix length; the committed default provides 256
  `/21` networks. To use multiple pools, quote a semicolon-separated value, for
  example:
  ```bash
  DIND_DEFAULT_ADDRESS_POOLS="base=10.200.0.0/13,size=21;base=172.16.0.0/12,size=20"
  ```
- The repo is mounted into DinD at the same absolute path. Any config value that
  points outside the repo, such as a local Claude package or dataset path, must
  be made visible inside DinD with `DIND_MOUNTS`, for example:
  ```bash
  DIND_MOUNTS=/data/datasets:/data/datasets,/cache/claude:/cache/claude \
    ./scripts/dind-run.sh --taskset terminalbench21 --agent claude-code --workers 1
  ```
- Existing DinD containers keep their original daemon mirror flags. If you
  change `DIND_REGISTRY_MIRRORS` or `DIND_DEFAULT_ADDRESS_POOLS`, rerun with
  `DIND_RESET=1`.
- Nested service ports are not reachable from the host unless exposed with
  `DIND_PORTS`.

## Tips & Caveats

- **Run setup.sh before run_fleet.sh**: setup installs the environment, run_fleet launches the fleet. Skipping setup will almost certainly fail.
- **Harbor before OpenClaw**: harbor is lighter (single container); openclaw needs 10 containers.
- **Verify the endpoint after switching models**: after changing `MODEL`, first `curl` the gateway to confirm it responds, then launch the fleet.
- **Intranet / offline hosts**: setup.sh installs Node.js via nvm and Claude Code via npm, both reaching the public internet. On a network without public access, install Node.js >= 18 manually first. Benchmark containers also pull Claude Code from `downloads.claude.ai` by default; provide a local Claude package at setup time:
  ```bash
  CLAUDE_TGZ_SOURCE=/path/to/claude-code.tgz \
  CLAUDE_WHEEL_DIR_SOURCE=/path/to/wheels/ \
  ./scripts/setup.sh
  ```
- **Clean up old runs**: openclaw leaves `.smoke-openclaw-*` directories and containers behind; clean them periodically:
  ```bash
  docker rm -f $(docker ps -aq --filter "name=ocsmoke-" --filter "name=ocpb-")
  rm -rf .smoke-openclaw-*
  ```
- **Do not commit `config.local.env`**: it contains secrets.
- **`bypassPermissions` mode**: the agent executes all tool calls automatically; only use in a controlled environment.
- **Sessions and background execution**: use the facilities provided by the selected Harbor or OpenClaw runner. The router does not manage sessions.
