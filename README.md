# SII Agent Fleet

SII Agent Fleet provides runnable agent integrations and benchmark task lists for evaluating Claude Code, OpenCode, and OpenClaw.

## Quick Start

### Step 0 — Prerequisites

Install before you begin:

* Docker + Docker Compose v2
* Python >= 3.9
* git, curl, jq, openssl
* tmux + zellij — verified on tmux 3.2a / zellij 0.44.3
  (`sudo apt install tmux`; zellij via [releases](https://github.com/zellij-org/zellij/releases))

> Only Docker Compose v2 and Python >= 3.9 have a minimum version; the rest just need to be installed.
> Node.js >= 18 and Claude Code are installed automatically by `setup.sh` — no need to install them manually.

```bash
# Clone this repo to local disk
git clone --recurse-submodules https://github.com/sii-system/sii-agent-fleet.git
cd sii-agent-fleet
```

### Step 1 — Configure

Export your model gateway credentials:

```bash
export BASE_URL=https://your-model-gateway.example.com   # Model gateway URL, WITHOUT /v1
export API_KEY=your-api-key                         # Model gateway API key
export MODEL=your_model_id
export TRACE_TO_OPIK=true                           # Set false to disable Opik fleet-wide
export OPIK_URL=https://your-opik-host/api          # Opik tracing endpoint, used by the Harbor/ClawBio runtime
```

`OPIK_URL` is required by the benchmark runtime while tracing is enabled
(the default); setup only persists it into `config.local.env`. To run
without an Opik server, set `TRACE_TO_OPIK=false`; this also disables the
OpenClaw plugin and PinchBench tracer paths.

### Step 2 — Run setup.sh

```bash
./scripts/setup.sh          # one-shot environment bootstrap
```

### Step 3 — Run a fleet

```bash
./scripts/run_fleet.sh --taskset <taskset> [--agent <agent>] [--workers <n>] [options]
```

* `--taskset <taskset>` — required, taskset to run
* `--agent claude-code|opencode|openclaw` — optional; `openclaw` is for OpenClaw tasksets
* `--workers <n>` — optional, concurrency (default `10`)

## Rerun

```bash
# ./scripts/setup.sh    # re-run only if config changed
./scripts/run_fleet.sh --taskset <taskset>
```

## More details

- Scripts (setup.sh / run_fleet.sh): [scripts/README.md](./scripts/README.md)
- Skills: [skills/README.md](./skills/README.md)
- Repository structure: [STRUCT.md](./STRUCT.md)
- Harbor runner: [Agents/utils/common/Harbor/STRUCT.md](./Agents/utils/common/Harbor/STRUCT.md)
