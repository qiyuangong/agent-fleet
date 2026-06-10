# Harbor Runner

This directory contains the shared Harbor runner for Claude Code and OpenCode.

The normal workflow is:

```bash
cd Agents/utils/common/Harbor
vim env.sh
bash start.sh --detach
```

Use `bash start.sh` instead of `--detach` for an interactive zellij session.

Optional console-only online analysis:

```bash
HARBOR_ONLINE_ANALYSIS=1 bash start.sh --detach
```

## Minimal Setup

Point the runner at your infrastructure. `config.env` is a committed template;
copy it to a git-ignored `config.local.env` (sourced after, and overriding,
`config.env`) and set your values — including credentials — there:

```bash
cp config.env config.local.env
vim config.local.env
```

Set your model gateway, Opik endpoint, and package mirrors there:

```bash
BASE_URL=https://your-openai-compatible-endpoint
API_KEY=your-api-key
MODEL=your-model-id
OPIK_URL=http://your-opik-host/api
OPIK_PROJECT_NAME=your-project-name
```

Then edit the run parameters in `env.sh`:

```bash
AGENT="claude-code"        # claude-code or opencode
DATASET_NAME="seta"        # seta, smith, terminalbench21, or sweverify
DATASET_PATH="/workspace/seta-env/Harbor-Dataset"
TOTAL_WORKERS="80"
TB_N_CONCURRENT="80"
```

The Opik tracing plugin is loaded from the `third_party/sii-opik-plugin`
submodule. Initialize it before running:

```bash
git submodule update --init --recursive
```

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
