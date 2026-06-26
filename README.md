# SII Agent Fleet

SII Agent Fleet provides runnable agent integrations and benchmark task lists for Harbor-based evaluation. The main supported Harbor agents are Claude Code and OpenCode.

## Prerequisites

* Docker + Docker Compose v2
* Python >= 3.9
* git
* zellij
* Others: npm, jq, openssl

## Quick Start: Harbor

Clone the repository with the Opik plugin submodule:

```bash
git clone --recurse-submodules https://github.com/sii-system/sii-agent-fleet.git
```

If you already cloned the repository without submodules, initialize them before
using Opik-enabled agents:

```bash
git submodule update --init --recursive
```

Point the fleet at your infrastructure. `config.env` is a committed template;
copy it to a git-ignored `config.local.env` (sourced after, and overriding,
`config.env`) and put your real values — including credentials — there:

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

Then choose the run parameters in the Harbor environment file:

```bash
cd Agents/utils/common/Harbor
vim env.sh
```

Set the basic fields in `env.sh`:

```bash
AGENT="claude-code"        # claude-code or opencode
DATASET_NAME="seta"        # seta, smith, terminalbench21, or sweverify
DATASET_PATH="/workspace/seta-env/Harbor-Dataset"
TOTAL_WORKERS="80"
TB_N_CONCURRENT="80"
```

Start the run:

```bash
bash start.sh --detach
```

For an interactive zellij session:

```bash
bash start.sh
```

Attach to a detached session with the name printed by `start.sh`:

```bash
zellij attach <session-name>
```

## Supported Harbor Datasets

Configure the dataset in `env.sh`:

| Dataset | `DATASET_NAME` | Typical `DATASET_PATH` |
| --- | --- | --- |
| SETA | `seta` | `/workspace/seta-env/Harbor-Dataset` |
| SWE-Smith | `smith` | `/workspace/harbor/datasets/swesmith` |
| Terminal-Bench 2.1 | `terminalbench21` | `/workspace/terminal-bench-2-1/tasks` |
| SWE-bench Verified | `sweverify` | `/workspace/swebench-verified` |

## Use Skills to Operate Fleet/Benchmark

0. Prerequisites:
* Login to the target server.
* Set up a code agent such as Claude Code, OpenCode, or Pi.

1. Install or load the skills for your code agent according to [Install Skills](./skills/README.md#install-skills).

2. Configure private runtime values when needed:

```bash
cp config.env config.local.env
vim config.local.env
```

3. Prompt the code agent to operate the fleet or run benchmarks on the target server.

   > [!NOTE]
   > The e2e prompt examples usually take 10-20 minutes, depending on environment readiness.
   > Use a persistent terminal session such as `tmux` or `zellij` so the run can continue if the connection drops.

```bash
PROMPT_FILE=./skills/e2e-harbor-benchmark.txt
# PROMPT_FILE=./skills/e2e-openclaw-benchmark.txt

# Claude Code: run the selected prompt file.
claude --no-session-persistence --permission-mode bypassPermissions --tools default -p "$(cat "$PROMPT_FILE")"

# OpenCode: run the selected prompt file.
opencode run --dangerously-skip-permissions "$(cat "$PROMPT_FILE")"

# Pi: run the selected prompt file.
pi --no-session --approve --tools read,bash,edit,write,grep,find,ls -p "$(cat "$PROMPT_FILE")"
```

These prompts have been verified with GLM-5.1:

- [`e2e-openclaw-benchmark.txt`](./skills/e2e-openclaw-benchmark.txt) — set up the OpenClaw fleet and run OpenClaw benchmark smoke tests
- [`e2e-harbor-benchmark.txt`](./skills/e2e-harbor-benchmark.txt) — run Harbor benchmark smoke tests

## More Details

- Repository structure: [STRUCT.md](./STRUCT.md)
- Harbor runner details and variables: [Agents/utils/common/Harbor/STRUCT.md](./Agents/utils/common/Harbor/STRUCT.md)
- Harbor Claude Code integration: [Agents/Harbor-claude-code/STRUCT.md](./Agents/Harbor-claude-code/STRUCT.md)
- Harbor OpenCode integration: [Agents/Harbor-opencode/STRUCT.md](./Agents/Harbor-opencode/STRUCT.md)
