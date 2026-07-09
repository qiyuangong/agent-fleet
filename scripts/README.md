# scripts/ — Setup & Fleet Launch Entry Points

| Script | Purpose |
| --- | --- |
| `setup.sh` | One-shot environment bootstrap: installs Node + Claude Code, writes config, installs skills |
| `run_fleet.sh` | Launch a fleet to run tasks: load config → create tmux → invoke claude agent |

For the end-to-end quick start, see the [root README](../README.md#quick-start).

---

## setup.sh

### Usage

```bash
./scripts/setup.sh
# Interactive prompt for BASE_URL / API_KEY / MODEL
```

Or pre-fill via env vars (suitable for automation):

```bash
BASE_URL=https://your-model-gateway.example.com \
API_KEY=your-token \
MODEL=glm-5.1-fp8 \
./scripts/setup.sh
```

**Prerequisites**: Manually install `git` / `curl` / `docker` / `python3`. Node and Claude Code do not need to be pre-installed.

### Details

<details>
<summary>What setup.sh does</summary>

1. Gather model endpoint config (interactive prompt or env vars)
2. Check base dependencies (git / curl / docker / python3)
3. Install Node.js via nvm (if missing or < 18)
4. Install Claude Code (pinned to 2.1.90)
5. Write env vars to `~/.bashrc`
6. Clone the repo + install the skills plugin
7. Write `config.local.env`
8. Check Docker permissions

</details>

<details>
<summary>Idempotency notes</summary>

- `~/.bashrc`: wrapped in a marker block `# >>> sii-agent-fleet env >>>`, the whole block is replaced each run
- `~/.claude/settings.json`: managed keys are merged, user customizations preserved
- `config.local.env`: only managed keys are updated, comments and other keys are preserved
- A backup is taken before each modification (`*.bak.sii-agent-fleet`)

Safe to re-run.

</details>

---

## run_fleet.sh

### Usage

```bash
./scripts/run_fleet.sh --taskset <taskset> [--agent <agent>] [--workers <n>] [options]
```

**One-off env overrides** (temporarily switch model/endpoint without editing config files):

```bash
MODEL=gpt-4o ./scripts/run_fleet.sh --taskset terminalbench21 --agent claude-code --workers 1
BASE_URL=https://other-gateway.example.com ./scripts/run_fleet.sh --taskset seta
```

**Prerequisites**: `setup.sh` has been run (or equivalent manual configuration completed).

### Details

<details>
<summary>Run flow</summary>

1. Parse `--taskset` / `--agent` / `--workers` and validate against the taskset registry
2. Load `config.env` → `config.local.env` → restore caller env (command-line overrides win)
3. Derive `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` from `BASE_URL` / `API_KEY`
4. Generate `RUN_ID` (`<taskset>-<timestamp>`)
5. Print a run summary and (in interactive mode) wait for confirmation
6. Create a tmux session named after `RUN_ID`
7. Run `claude --plugin-dir <skills> --permission-mode bypassPermissions -p "<prompt>"` inside tmux
8. Pipe output via `tee` to `scripts/logs/<RUN_ID>.log`

</details>

<details>
<summary>tmux operations</summary>

The tmux session is named after `RUN_ID` (e.g. `terminalbench21-0707-153000`).

| Operation | Command |
| --- | --- |
| Reattach | `tmux attach -t <RUN_ID>` |
| Detach | `Ctrl+B` then `D` |
| Scroll | Mouse wheel |
| Kill session | `tmux kill-session -t <RUN_ID>` |

If a session already exists, the script refuses to create a duplicate and prompts you to attach or kill it.

</details>

<details>
<summary>Logs</summary>

```
scripts/logs/<RUN_ID>.log
```

> **Known issue**: `claude | tee` pipe buffering may leave the log file at 0 bytes.
> If this happens, check the tmux terminal output or the benchmark result directory.

</details>

---

## Tips & Caveats

- **Run setup.sh before run_fleet.sh**: setup installs the environment, run_fleet launches the fleet. Skipping setup will almost certainly fail.
- **Harbor before OpenClaw**: harbor is lighter (single container); openclaw needs 10 containers.
- **Verify the endpoint after switching models**: after changing `MODEL`, first `curl` the gateway to confirm it responds, then launch the fleet.
- **Intranet / offline hosts**: setup.sh installs Node.js via nvm and Claude Code via npm, both reaching the public internet. On a network without public access, install Node.js >= 18 manually first. Benchmark containers also pull Claude Code from `downloads.claude.ai` by default; provide a local Claude package at setup time:
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
