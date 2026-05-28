# Harbor Common Structure

This directory contains shared Harbor orchestration code. It does not own task lists or agent-specific integration code.

## Files

```text
Agents/utils/common/Harbor/
├── start.sh                    # Main zellij launcher
├── env.sh                      # Path resolution and runtime defaults
├── gen_harbor_zellij_layout.sh # zellij layout generator
├── monitor_harbor.sh           # Run monitor pane
├── run_harbor_worker.sh        # Worker loop for one zellij pane
├── harboropik.sh               # Harbor CLI wrapper with Opik setup
├── prepare_local_deps.sh       # Local package/cache preparation
├── harbor_prepare_runner_cli.py
└── harbor_worker_utils.py
```

## Path Resolution

`env.sh` computes paths relative to this file:

- `REPO_ROOT`: repository root
- `AGENTS_DIR`: `REPO_ROOT/Agents`
- `TASKS_DIR`: `REPO_ROOT/Tasks`
- `HARBOR_CLAUDE_CODE_DIR`: Claude Code integration directory
- `HARBOR_OPENCODE_DIR`: OpenCode integration directory

## Task Resolution

`DATASET_NAME` selects a built-in task list:

- `seta`: `Tasks/SETA/harbor_tasks.txt`
- `sweverify`: `Tasks/SWE-verify/harbor_tasks.txt`
- `smith`: `Tasks/SWE-smith/harbor_tasks.txt`
- `terminalbench21`: `Tasks/Terminal-bench-2/harbor_terminalbench21_tasks.txt`

`TASK_SOURCE_FILE` overrides the built-in selection.

Typical dataset paths:

| Dataset | `DATASET_NAME` | `DATASET_PATH` | Metric | Suggested workers |
| --- | --- | --- | --- | --- |
| SETA | `seta` | `/workspace/seta-env/Harbor-Dataset` | success rate | `80` |
| SWE-Smith | `smith` | `/workspace/harbor/datasets/swesmith` | reward | `80` |
| Terminal-Bench 2.1 | `terminalbench21` | `/workspace/terminal-bench-2-1/tasks` | success rate | `20` |
| SWE-bench Verified | `sweverify` | `/workspace/swebench-verified` | success rate | `20` |

## Main Variables

| Variable | Purpose |
| --- | --- |
| `AGENT` | `claude-code` or `opencode` |
| `MODEL` | Model name passed to Harbor |
| `BASE_URL` | Model gateway base URL |
| `API_KEY` | Model gateway API key |
| `DATASET_NAME` | Built-in task list selector |
| `DATASET_PATH` | Local dataset directory |
| `TASK_SOURCE_FILE` | Explicit task list path |
| `TOTAL_WORKERS` | Number of zellij workers |
| `TB_N_CONCURRENT` | Harbor concurrency, normally the same as `TOTAL_WORKERS` |
| `RUN_ID` | Run name |
| `OUTPUT_ROOT` | Parent directory for runs |
| `OUTPUT_PATH` | Full output directory |
| `OPIK_URL` | Opik API URL, usually ending in `/api` |
| `OPIK_URL_OVERRIDE` | Opik API URL forwarded into task containers |
| `OPIK_API_KEY` | Opik API key |
| `OPIK_PROJECT_NAME` | Opik project name |
| `OPIK_PLUGIN_WORKSPACE` | Local `sii-opik-plugin` checkout, default `/workspace/sii-opik-plugin` |
| `OPIK_PLUGIN_GIT_URL` | Git URL used when the plugin checkout must be cloned |
| `OPIK_PLUGIN_GIT_REF` | Plugin Git ref checked out after clone |
| `TRACE_PLUGIN_SOURCE_DIR` | Tracing source path, defaults to `OPIK_PLUGIN_WORKSPACE` |
| `TRACE_TO_OPIK` | Enables or disables trace upload |
| `CLAUDE_CODE_VERSION` | Claude Code package version used by local dependency cache |
| `OPENCODE_VERSION` | OpenCode package version used by local dependency cache |
| `LOCAL_WHEEL_DIR` | Local dependency cache directory |
| `LOCAL_WHEEL_PORT` | Preferred local dependency HTTP server port |
| `LOCAL_WHEEL_PORT_ATTEMPTS` | Number of local port attempts |
| `TB_REMOTE_WHEEL_SERVER_URLS` | Comma-separated fallback dependency cache URLs |
| `TB_SKIP_DOCKERHUB_PREFLIGHT` | Skip Docker Hub preflight connectivity check |
| `TB_FORCE_BUILD` | Build task images locally instead of using prebuilt images |
| `TB_TIMEOUT_MULTIPLIER` | General Harbor timeout multiplier |
| `TB_AGENT_TIMEOUT_MULTIPLIER` | Agent execution timeout override |
| `TB_AGENT_SETUP_TIMEOUT_MULTIPLIER` | Agent setup timeout multiplier |

## Agent Variables

Claude Code specific defaults:

- `CLAUDE_CODE_VERSION`
- `TB_ANTHROPIC_BASE_URL`
- `TB_ANTHROPIC_AUTH_TOKEN`
- `TB_ANTHROPIC_MODEL`
- `TB_ANTHROPIC_DEFAULT_OPUS_MODEL`
- `TB_ANTHROPIC_DEFAULT_SONNET_MODEL`
- `TB_ANTHROPIC_DEFAULT_HAIKU_MODEL`
- `TB_CLAUDE_CODE_SUBAGENT_MODEL`
- `TB_CLAUDE_CODE_EFFORT_LEVEL`
- `TB_CLAUDE_CODE_MAX_OUTPUT_TOKENS`
- `TB_CC_HOOK_SOURCE`

OpenCode specific defaults:

- `OPENCODE_VERSION`
- `OPENCODE_PROVIDER`
- `OPENCODE_CONFIG_CONTENT`
- `TRACE_PLUGIN_OPENCODE_PLUGIN_SOURCE`
- `TRACE_PLUGIN_OPENCODE_HOOK_SOURCE`

## Opik Plugin Workspace

`start.sh` and `monitor_harbor.sh` call `harbor_ensure_opik_plugin_workspace`
before launching workers. The check requires:

```text
Claude Code:
  $OPIK_PLUGIN_WORKSPACE/src/sii_opik_plugin/claude_code/claude_realtime_trace.py

OpenCode:
  $OPIK_PLUGIN_WORKSPACE/harness/opencode/opik-trace.ts
  $OPIK_PLUGIN_WORKSPACE/src/sii_opik_plugin/opencode/opencode_realtime_trace.py
```

If these files are missing and `OPIK_PLUGIN_WORKSPACE` does not exist, the
runner runs:

```bash
git clone "$OPIK_PLUGIN_GIT_URL" "$OPIK_PLUGIN_WORKSPACE"
git -C "$OPIK_PLUGIN_WORKSPACE" checkout "$OPIK_PLUGIN_GIT_REF"
```

If the plugin repository is private or network access is restricted, place a
complete checkout at `OPIK_PLUGIN_WORKSPACE` before running.

## Execution Flow

1. `start.sh` sources `env.sh`, validates `AGENT`, ensures the Opik plugin checkout once, initializes output directories, and prepares the task file.
2. `gen_harbor_zellij_layout.sh` writes a zellij layout with monitor and worker panes.
3. Each worker pane runs `run_harbor_worker.sh`.
4. Workers claim tasks from the shared queue and call `harboropik.sh`.
5. `harboropik.sh` prepares Opik/tracing settings and invokes Harbor with either Claude Code or OpenCode.
