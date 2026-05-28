# Harbor Runner

This directory contains the shared Harbor runner for Claude Code and OpenCode.

The normal workflow is:

```bash
cd Agents/utils/common/Harbor
vim env.sh
bash start.sh --detach
```

Use `bash start.sh` instead of `--detach` for an interactive zellij session.

## Minimal Setup

Edit these fields in `env.sh`:

```bash
AGENT="claude-code"        # claude-code or opencode
DATASET_NAME="seta"        # seta, smith, terminalbench21, or sweverify
DATASET_PATH="/workspace/seta-env/Harbor-Dataset"
TOTAL_WORKERS="80"
TB_N_CONCURRENT="80"

MODEL="minimax2.7"
BASE_URL="https://your-openai-compatible-endpoint"
API_KEY="your-api-key"

OPIK_PLUGIN_WORKSPACE="/workspace/sii-opik-plugin"
OPIK_URL="http://your-opik-host/api"
OPIK_PROJECT_NAME="your-project-name"
```

`OPIK_PLUGIN_WORKSPACE` must point to a complete `sii-opik-plugin` checkout. If the path is missing, the runner tries to clone the plugin automatically. For private plugin repositories, prepare `/workspace/sii-opik-plugin` manually before running.

## Datasets

Use these values in `env.sh`:

| Dataset | `DATASET_NAME` | Typical `DATASET_PATH` | Suggested workers |
| --- | --- | --- | --- |
| SETA | `seta` | `/workspace/seta-env/Harbor-Dataset` | `80` |
| SWE-Smith | `smith` | `/workspace/harbor/datasets/swesmith` | `80` |
| Terminal-Bench 2.1 | `terminalbench21` | `/workspace/terminal-bench-2-1/tasks` | `20` |
| SWE-bench Verified | `sweverify` | `/workspace/swebench-verified` | `20` |

## More Details

Architecture, script roles, task resolution, and full variable descriptions are in [STRUCT.md](./STRUCT.md).
