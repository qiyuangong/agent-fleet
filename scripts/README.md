# scripts/ — Setup & Fleet Launch Entry Points

| Script | Purpose |
| --- | --- |
| `setup.sh` | One-shot environment bootstrap: installs Node + Claude Code, writes config, installs skills |
| `run_fleet.sh` | Launch a fleet to run tasks: load config → create tmux → invoke claude agent |

## Quick Start

```bash
# 1. One-shot environment bootstrap (interactive prompt for BASE_URL / API_KEY / MODEL)
./scripts/setup.sh
source ~/.bashrc

# 2. Launch a fleet to run tasks
./scripts/run_fleet.sh harbor    # Harbor: 3 SETA + 3 Terminal-Bench-2
./scripts/run_fleet.sh openclaw  # OpenClaw: 10 fleet + 3 PinchBench + 3 ClawBio
```

---

## setup.sh

**Purpose**: One-shot, idempotent environment bootstrap. It performs:

1. Gather model endpoint config (interactive prompt or env vars)
2. Check base dependencies (git / curl / docker / python3)
3. Install Node.js via nvm (if missing or < 18)
4. Install Claude Code (pinned to 2.1.90)
5. Write env vars to `~/.bashrc`
6. Clone the repo + install the skills plugin
7. Write `config.local.env`
8. Check Docker permissions

**Prerequisites**: Manually install `git` / `curl` / `docker` / `python3`. Node and Claude Code do not need to be pre-installed.

**Usage**:

```bash
./scripts/setup.sh
# Interactive prompt for BASE_URL / API_KEY / MODEL
```

Or pre-fill via env vars (suitable for automation):

```bash
BASE_URL=https://your-gateway.example.com \
API_KEY=your-token \
MODEL=glm-5.1-fp8 \
./scripts/setup.sh
```

<details>
<summary>Overridable variables</summary>

| Variable | Default | Description |
| --- | --- | --- |
| `NODE_VERSION` | `24` | Node.js major version |
| `CLAUDE_CODE_VERSION` | `2.1.90` | Claude Code version |
| `REPO_URL` | `https://github.com/sii-system/sii-agent-fleet.git` | URL used for cloning |
| `REPO_DIR` | `$HOME/sii-agent-fleet` | Clone destination path |
| `CLAUDE_TGZ_SOURCE` | (empty) | Local Claude Code tgz, for offline install inside containers |
| `CLAUDE_WHEEL_DIR_SOURCE` | (empty) | Local Python wheel directory, must contain `npm-cache/` |

</details>

<details>
<summary>Idempotency notes</summary>

- `~/.bashrc`: wrapped in a marker block `# >>> sii-agent-fleet env >>>`, the whole block is replaced each run
- `~/.claude/settings.json`: managed keys are merged, user customizations preserved
- `config.local.env`: only managed keys are updated, comments and other keys are preserved
- A backup is taken before each modification (`*.bak.sii-agent-fleet`)

Safe to re-run.

</details>

**After running**: `source ~/.bashrc` to apply the new env vars, then you can run `run_fleet.sh`.

---

## run_fleet.sh

**Purpose**: Load config → pin Claude version → create tmux → invoke the claude agent to run an e2e benchmark.

**Prerequisites**: `setup.sh` has been run (or equivalent manual configuration completed).

**Usage**:

```bash
./scripts/run_fleet.sh harbor    # Harbor smoke test
./scripts/run_fleet.sh openclaw  # OpenClaw fleet smoke test
```

**One-off env overrides** (temporarily switch model/endpoint without editing config files):

```bash
MODEL=gpt-4o ./scripts/run_fleet.sh harbor
BASE_URL=https://other-gateway.example.com ./scripts/run_fleet.sh openclaw
```

<details>
<summary>Run flow</summary>

1. Parse arguments and select the prompt file (`skills/e2e-{harbor,openclaw}-benchmark.txt`)
2. Load `config.env` → `config.local.env` → restore caller env (command-line overrides win)
3. Derive `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` from `BASE_URL` / `API_KEY`
4. Pin the Claude Code version (disable auto-update)
5. Configure the local Claude install package (if set)
6. Create a tmux session (`harbor-bench` or `openclaw-bench`)
7. Run `claude --plugin-dir <skills> --permission-mode bypassPermissions -p "<prompt>"` inside tmux
8. Pipe output via `tee` to `scripts/logs/<bench>_<timestamp>.log`

</details>

<details>
<summary>tmux operations</summary>

| Operation | Command |
| --- | --- |
| Reattach | `tmux attach -t harbor-bench` / `tmux attach -t openclaw-bench` |
| Detach | `Ctrl+B` then `D` |
| Scroll | Mouse wheel |
| Kill session | `tmux kill-session -t harbor-bench` |

If a session already exists, the script refuses to create a duplicate and prompts you to attach or kill it.

</details>

<details>
<summary>Logs</summary>

```
scripts/logs/<bench>_<YYYYMMDD>_<HHMMSS>.log
```

> **Known issue**: `claude | tee` pipe buffering may leave the log file at 0 bytes.
> If this happens, check the tmux terminal output or the benchmark result
> directory (`~/harbor-runs/` or `.smoke-openclaw-*/`).

</details>

---

## Tips & Caveats

- **Run setup.sh before run_fleet.sh**: setup installs the environment, run_fleet launches the fleet. Skipping setup will almost certainly fail.
- **Harbor before OpenClaw**: harbor is lighter (single container); openclaw needs 10 containers.
- **Verify the endpoint after switching models**: after changing `MODEL`, first `curl` the gateway to confirm it responds, then launch the fleet.
- **Configure a local Claude package on intranets**: without `CLAUDE_TGZ_SOURCE`, containers will hit `downloads.claude.ai`, which usually times out on intranets. Pass it at setup time:
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
- **SSH disconnects**: run_fleet.sh must run in tmux mode (the default), otherwise a disconnect kills the task.
