# SII Agent Fleet

SII Agent Fleet provides runnable agent integrations and benchmark task lists for Harbor-based evaluation. The main supported Harbor agents are Claude Code and OpenCode.

## Quick Start: Harbor

Prepare the Opik plugin checkout. The default location is:

```bash
/workspace/sii-opik-plugin
```

If the plugin repository is private or the runtime cannot access GitHub, place a complete `sii-opik-plugin` checkout there before running.

Edit the Harbor environment file:

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

MODEL="minimax2.7"
BASE_URL="https://your-openai-compatible-endpoint"
API_KEY="your-api-key"

OPIK_PLUGIN_WORKSPACE="/workspace/sii-opik-plugin"
OPIK_URL="http://your-opik-host/api"
OPIK_PROJECT_NAME="your-project-name"
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

## More Details

- Repository structure: [STRUCT.md](./STRUCT.md)
- Harbor runner details and variables: [Agents/utils/common/Harbor/STRUCT.md](./Agents/utils/common/Harbor/STRUCT.md)
- Harbor Claude Code integration: [Agents/Harbor-claude-code/STRUCT.md](./Agents/Harbor-claude-code/STRUCT.md)
- Harbor OpenCode integration: [Agents/Harbor-opencode/STRUCT.md](./Agents/Harbor-opencode/STRUCT.md)
