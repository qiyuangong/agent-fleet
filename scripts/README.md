# scripts/ — Setup & Fleet Launch Entry Points

| Script | Purpose |
| --- | --- |
| `setup.sh` | One-shot environment bootstrap: installs Node + Claude Code, writes config, installs skills |
| `run_fleet.sh` | Routes tasksets to the existing Harbor or OpenClaw runner |

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
| `workers` | No | Positive integer |

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
