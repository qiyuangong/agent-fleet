# Repository Structure

SII Agent Fleet separates runnable agents, task assets, and TUI deployment code so each part can be used independently.

```text
sii-agent-fleet/
├── Agents/
│   ├── Openclaw/              # Dockerized OpenClaw gateway fleet
│   ├── Harbor-claude-code/    # Claude Code tracing/integration code
│   ├── Harbor-opencode/       # OpenCode tracing/integration code
│   └── utils/
│       └── common/Harbor/     # Shared Harbor runner, zellij layout, workers
├── Tasks/
│   ├── Pinchbench/            # PinchBench runner for OpenClaw
│   ├── clawBio/               # ClawBio runner for OpenClaw
│   ├── SWE-verify/            # SWE-bench Verified task list
│   ├── SWE-smith/             # SWE-Smith task list
│   ├── Terminal-bench-2/      # Terminal-Bench task lists
│   └── SETA/                  # SETA task lists
├── TUI/
│   ├── deploy/                # Agent and gateway deployment scripts
│   ├── Dashboard/             # Dashboard static assets
│   └── Nginx/                 # Nginx config and zellij discovery script
```

## Design

`Agents/` owns execution. Agent-specific code stays under its own directory, while shared Harbor orchestration lives under `Agents/utils/common/Harbor/`.

`Tasks/` owns benchmark and task inputs. Harbor and OpenClaw runners read task lists from here instead of duplicating task files inside agent directories.

`TUI/` owns operator-facing deployment assets. It deploys the dashboard gateway and the per-machine zellij discovery service.

## Cross-Directory Calls

Harbor common resolves the repository root from `Agents/utils/common/Harbor/env.sh`, then derives:

- `AGENTS_DIR=$REPO_ROOT/Agents`
- `TASKS_DIR=$REPO_ROOT/Tasks`
- `HARBOR_CLAUDE_CODE_DIR=$AGENTS_DIR/Harbor-claude-code`
- `HARBOR_OPENCODE_DIR=$AGENTS_DIR/Harbor-opencode`

OpenClaw benchmark runners call `Agents/Openclaw` for fleet setup and Docker Compose, then use task-specific code under `Tasks/Pinchbench` or `Tasks/clawBio`.

TUI deployment scripts read `TUI/Dashboard`, `TUI/Nginx/config`, and `TUI/Nginx/scripts` directly.

Opik tracing code is loaded from `OPIK_PLUGIN_WORKSPACE`, defaulting to
`/workspace/sii-opik-plugin`; it is not vendored into this repository. Harbor
and OpenClaw entrypoints can clone `OPIK_PLUGIN_GIT_URL` when the checkout is
missing, but private plugin repositories should be prepared locally before a
run.
