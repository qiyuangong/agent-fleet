# SII Agent Fleet

SII Agent Fleet provides runnable agent integrations and benchmark task lists for Harbor-based evaluation. The main supported Harbor agents are Claude Code and OpenCode.

## Quick Start

**Where to run:** a Linux host (or VM) with Docker installed and network
access to your OpenAI-compatible LLM gateway. Both `setup.sh` and
`run_fleet.sh` run on this host; benchmarks are launched as Docker containers.

### Step 0 — Prerequisites

Install these manually before you begin:

* Docker + Docker Compose v2
* Python >= 3.9
* git, curl, jq, openssl
* tmux (used by `run_fleet.sh` for persistent sessions)
* zellij (used by the Harbor runner's interactive mode)

`setup.sh` can install Node.js and Claude Code for you; the tools above must
be installed manually before running setup.

### Step 1 — Clone (with Opik plugin submodule)

```bash
git clone --recurse-submodules https://github.com/sii-system/sii-agent-fleet.git
cd sii-agent-fleet
```

### Step 2 — One-shot setup

```bash
# Installs Node + Claude Code, writes config.local.env, installs skills plugin
./scripts/setup.sh
```

`setup.sh` will interactively prompt for:

* `BASE_URL` — your OpenAI-compatible LLM gateway URL (without `/v1`)
* `API_KEY` — API key for that gateway
* `MODEL` — model id to evaluate (e.g. `glm-5.1-fp8`)

Reopen your terminal (`source ~/.bashrc`) after setup completes so the new
environment variables take effect before running step 3.

### Step 3 — Launch a fleet run

```bash
./scripts/run_fleet.sh harbor    # Harbor smoke test (SETA + Terminal-Bench-2)
./scripts/run_fleet.sh openclaw  # OpenClaw fleet + PinchBench + ClawBio smoke
```

> [!TIP]
> To change the model, agent, dataset, or concurrency, override via env vars
> (e.g. `MODEL=... TOTAL_WORKERS=4 ./scripts/run_fleet.sh harbor`) or edit
> `config.local.env`. The Harbor runner also reads `Agents/utils/common/Harbor/env.sh`
> for `AGENT`, `DATASET_NAME`, `TOTAL_WORKERS`, etc. See
> [scripts/README.md](./scripts/README.md) for the full override list.

<details>
<summary>Manual setup (without setup.sh)</summary>

If you prefer to configure everything manually instead of using `setup.sh`:

```bash
cp config.env config.local.env
vim config.local.env   # set BASE_URL, API_KEY, MODEL, OPIK_URL
```

Required values in `config.local.env`:

```bash
BASE_URL=https://your-openai-compatible-endpoint   # WITHOUT /v1
API_KEY=your-api-key
MODEL=your-model-id
OPIK_URL=http://your-opik-host/api
```

Install Claude Code and skills plugin manually, then run `run_fleet.sh`.

</details>

---

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
# Required vars
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

### Supported Harbor Datasets

| Dataset | `DATASET_NAME` | Typical `DATASET_PATH` |
| --- | --- | --- |
| SETA | `seta` | `/workspace/seta-env/Harbor-Dataset` |
| SWE-Smith | `smith` | `/workspace/harbor/datasets/swesmith` |
| Terminal-Bench 2.1 | `terminalbench21` | `/workspace/terminal-bench-2-1/tasks` |
| SWE-bench Verified | `sweverify` | `/workspace/swebench-verified` |

---

## Use Skills to Operate Fleet/Benchmark

See [skills/README.md](./skills/README.md) for using e2e prompt files directly
with Claude Code, OpenCode, or Pi.

> [!TIP]
> `scripts/run_fleet.sh harbor|openclaw` wraps the skill-based flow with
> automatic env loading, version pinning, and tmux session management.

---

## More Details

- Scripts (setup.sh / run_fleet.sh): [scripts/README.md](./scripts/README.md)
- Repository structure: [STRUCT.md](./STRUCT.md)
- Harbor runner details and variables: [Agents/utils/common/Harbor/STRUCT.md](./Agents/utils/common/Harbor/STRUCT.md)
- Harbor Claude Code integration: [Agents/Harbor-claude-code/STRUCT.md](./Agents/Harbor-claude-code/STRUCT.md)
- Harbor OpenCode integration: [Agents/Harbor-opencode/STRUCT.md](./Agents/Harbor-opencode/STRUCT.md)
