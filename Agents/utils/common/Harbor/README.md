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
DATASET_NAME="seta"        # local alias, or a Harbor registry dataset id
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

For any Harbor registry dataset, pass the dataset id directly and use the normal
zellij entrypoint:

```bash
DATASET_NAME=openthoughts/tasktrove-swe-rebench-v2-patched-oracle \
bash Agents/utils/common/Harbor/start.sh --detach
```

Registry runs pass `--dataset "$DATASET_NAME"` to Harbor instead of preparing a
local task file from `DATASET_PATH`.

## RL Rollout Mode

Rollout mode exposes a Polar-compatible remote Harbor service instead of
starting a fixed dataset run.  It is gated by `ROLLOUT=1`; normal benchmark
runs are unchanged.

```bash
cd Agents/utils/common/Harbor
vim ../../rl/RL-env.sh
ROLLOUT=1 bash start.sh --detach
```

The service provides `GET /health`, `GET /datasets`,
`GET /datasets/{dataset_name}/tasks`, and `POST /run_trial`.  Requests are
queued, then per-job zellij workers run the same `harboropik.sh` path as normal
benchmark workers, so task panes keep the regular agent/tool logs.

Each `/run_trial` request must include a ray job id, for example `ray_job_id`,
`ray_submission_id`, or `metadata.ray_job_id`.  The service uses this id to
create/reuse one `harbor-rollout-<agent>-<dataset>-<ray_job_id>` zellij session;
requests without a job id are rejected instead of being queued without workers.

For Docker usage, publish the listener port and run the same command inside the
container:

```bash
docker run -d --name harbor-rollout \
  -p 19001:19001 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /workspace:/workspace \
  tb-plus-run:latest sleep infinity

docker exec harbor-rollout bash -lc '
  cd /workspace/sii-agent-fleet/Agents/utils/common/Harbor
  ROLLOUT=1 RL_HOST=0.0.0.0 RL_PORT=19001 bash start.sh --detach
'
```

For foreground debugging, source the same environment and run the listener
directly.  The listener still creates per-job zellij worker sessions for
requests with a ray job id.

```bash
cd Agents/utils/common/Harbor
ROLLOUT=1 . ./env.sh
python3 "$RL_UTILS_DIR/rollout_remote_harbor.py"
```

## Harbor Monitor

`start.sh` automatically starts one monitor for each Harbor benchmark run.
Set `HARBOR_MONITOR_ENABLED=0` to disable it. The monitor reads Fleet queue
artifacts for local datasets and Harbor job/trial results for registry datasets.

Equivalent queue monitor command:

```bash
RUN_DIR="$PWD/runs/example"
MONITOR_DIR="$RUN_DIR/monitor"

python3 Agents/utils/common/Harbor/scripts/monitor.py \
  --run-dir "$RUN_DIR" \
  --agent claude-code \
  --output "$MONITOR_DIR/monitor-latest.json" \
  --user-report-output "$MONITOR_DIR/user-notify-latest.json" \
  --analyzer-handover-output "$MONITOR_DIR/analyzer-handover-latest.json" \
  --runner-action-output "$MONITOR_DIR/runner-action-latest.json" \
  --follow --interval 30
```

Omit `--follow` for one sample. Control commands are optional executable files
inside `RUN_DIR`; arguments are allowed but shell syntax is not. If absent or
failed, the action becomes `notify`.

For automatic runs, optional run-local controls can be set with
`HARBOR_MONITOR_RESTART_CMD` and `HARBOR_MONITOR_STOP_CMD`.

| Output | Used by | Content |
| --- | --- | --- |
| `monitor-latest.json` | Debugging | Full state and evidence |
| `user-notify-latest.json` | User | Objective status and required human action |
| `analyzer-handover-latest.json` | Analyzer | Tasks requiring deeper analysis |
| `runner-action-latest.json` | Runner | `wait`, `restart`, `stop`, or `notify`, plus execution result |

All files are refreshed on each sample. The actual action is
`runner-action-latest.json.type`; the user report filename does not imply
`notify` was triggered.

| Observed state | Action |
| --- | --- |
| Worker active, including `suspected_stalled` | `wait` |
| Worker active past `--configured-timeout` | `notify` and continue monitoring |
| Tasks unfinished with no live worker | `restart`; after `--max-retries`, `notify` |
| Every task has a terminal queue record | `stop` |

Automatic restart is only used when tasks remain and no worker is alive.

## More Details

Architecture, script roles, task resolution, and full variable descriptions are in [STRUCT.md](./STRUCT.md).
