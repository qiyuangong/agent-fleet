#!/usr/bin/env bash
# ============================================================
# run_fleet.sh - run SII Agent Fleet benchmark (auto tmux + log saving)
# Usage:
#   ./run_fleet.sh harbor
#   ./run_fleet.sh openclaw
# ============================================================

set -euo pipefail

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"

# ---- Load nvm ----
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || true

# ---- Parse argument ----
BENCH="${1:-}"
case "$BENCH" in
  harbor)   PROMPT_REL="skills/e2e-harbor-benchmark.txt" ;;
  openclaw) PROMPT_REL="skills/e2e-openclaw-benchmark.txt" ;;
  ""|-h|--help)
    echo "Usage: $0 <benchmark>"
    echo "  harbor    run Harbor benchmark"
    echo "  openclaw  run OpenClaw benchmark"
    exit 0 ;;
  *)
    err "Unknown benchmark type: $BENCH"
    err "Available: harbor | openclaw"
    exit 1 ;;
esac

TMUX_SESSION="${BENCH}-bench"

# Derive REPO_DIR from SCRIPT_DIR (scripts/ is one level below repo root)
# so the wrapper works from any clone or worktree path. REPO_DIR remains
# an explicit override for non-standard layouts.
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# skills/README.md documents CLAUDE_PLUGIN_DIR as configurable.
PLUGIN_DIR="${CLAUDE_PLUGIN_DIR:-$HOME/.claude/skills/sii-agent-fleet}"

# ---- Load shared site configuration ----
# Follow the repo's precedence: caller env > config.local.env > config.env.
# Snapshot caller env first so file values don't shadow one-off overrides.
# This runs BEFORE the tmux handoff so one-off caller overrides (e.g.
# `BASE_URL=... ./run_fleet.sh harbor`) survive into the inner session:
# the resolved env is exported below and re-exported inside tmux.
__caller_env="$(export -p)"
if [[ -f "$REPO_DIR/config.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_DIR/config.env"
  set +a
fi
if [[ -f "$REPO_DIR/config.local.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_DIR/config.local.env"
  set +a
fi
eval "$__caller_env"
unset __caller_env

# ---- Confirm env vars ----
# Claude Code CLI reads ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN.
# Derive them from the repo-standard BASE_URL / API_KEY if the caller
# hasn't set the Anthropic vars directly. Normalize BASE_URL the same way
# as Agents/utils/common/Harbor/env.sh: strip a trailing /v1 so the
# top-level Claude invocation matches the benchmark runner's endpoint shape.
info "Confirming env vars..."
if [[ -z "${ANTHROPIC_BASE_URL:-}" && -n "${BASE_URL:-}" ]]; then
  BASE_URL_NORM="${BASE_URL%/}"
  BASE_URL_NORM="${BASE_URL_NORM%/v1}"
  export ANTHROPIC_BASE_URL="${BASE_URL_NORM}"
fi
if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" && -n "${API_KEY:-}" ]]; then
  export ANTHROPIC_AUTH_TOKEN="${API_KEY}"
fi
if [[ -z "${ANTHROPIC_AUTH_TOKEN:-}" || -z "${ANTHROPIC_BASE_URL:-}" ]]; then
  err "Env vars missing: set BASE_URL/API_KEY (or ANTHROPIC_BASE_URL/ANTHROPIC_AUTH_TOKEN) in config.local.env or shell"
  err "Run setup.sh first, or source $REPO_DIR/config.local.env"
  exit 1
fi
unset ANTHROPIC_API_KEY || true
ok "Env vars ready (BASE_URL=${ANTHROPIC_BASE_URL})"

# ---- Pin Claude Code version ----
# CLAUDE_CODE_DISABLE_AUTOUPDATER is the modern name (2.1.110+).
# DISABLE_AUTOUPDATER is the legacy name recognized by 2.1.90.
# Set both so the pin holds regardless of which version is installed.
export CLAUDE_CODE_DISABLE_AUTOUPDATER=1
export DISABLE_AUTOUPDATER=1

# ---- Local Claude package for benchmark containers ----
# Use the repo-standard TB_CC_* names (sourced from config above if set).
# Accept the short aliases as a convenience.
TGZ_SRC="${CLAUDE_TGZ_SOURCE:-${TB_CC_CLAUDE_TGZ_SOURCE:-}}"
WHEEL_SRC="${CLAUDE_WHEEL_DIR_SOURCE:-${TB_CC_PY_WHEEL_DIR_SOURCE:-}}"
if [[ -n "${TGZ_SRC}" && -n "${WHEEL_SRC}" && -f "${TGZ_SRC}" ]]; then
  export TB_CC_OPIK_ENABLE_HOOK=1
  export TB_CC_CLAUDE_TGZ_SOURCE="${TGZ_SRC}"
  export TB_CC_PY_WHEEL_DIR_SOURCE="${WHEEL_SRC}"
  ok "Containers will install Claude from local pkg: ${TGZ_SRC}"
else
  warn "No local Claude package configured; containers may try downloads.claude.ai (can fail on intranet)."
fi

# ---- tmux auto-management ----
# Snapshot the resolved env so the inner tmux session inherits it. tmux's
# server process is independent of the caller's shell, so neither assignment
# nor `export` of _RESOLVED_ENV reaches the inner session — we must pass it
# explicitly via `tmux new-session -e`.
_RESOLVED_ENV="$(export -p)"
if [[ -z "${TMUX:-}" && -z "${_IN_BENCH_TMUX:-}" ]]; then
  if ! command -v tmux >/dev/null 2>&1; then
    warn "tmux not installed, running directly (SSH disconnect will kill the task)"
  else
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
      err "tmux session '$TMUX_SESSION' already exists"
      err "Attach: tmux attach -t $TMUX_SESSION   or kill: tmux kill-session -t $TMUX_SESSION"
      exit 1
    fi
    info "Creating tmux session: $TMUX_SESSION and attaching..."
    info "(scroll: mouse wheel   detach: Ctrl+B then D   reattach: tmux attach -t $TMUX_SESSION)"
    tmux new-session -d -s "$TMUX_SESSION" -e "_RESOLVED_ENV=${_RESOLVED_ENV}" \
      "eval \"\${_RESOLVED_ENV}\"; _IN_BENCH_TMUX=1 '$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")' '$BENCH'; \
       echo; echo '[benchmark finished, press Enter to close]'; read"
    tmux set-option -t "$TMUX_SESSION" mouse on
    tmux set-option -t "$TMUX_SESSION" history-limit 50000
    tmux attach -t "$TMUX_SESSION"
    exit 0
  fi
fi
unset _RESOLVED_ENV

# ---- Actual run logic ----
info "Selected benchmark: $BENCH ($PROMPT_REL)"

# ---- Pre-flight checks ----
if ! command -v claude >/dev/null 2>&1; then
  err "claude command not found, run setup.sh first"; exit 1
fi
if [[ ! -d "$REPO_DIR" ]]; then
  err "Repo not found: $REPO_DIR, run setup.sh first"; exit 1
fi
PROMPT_FILE="$REPO_DIR/$PROMPT_REL"
if [[ ! -f "$PROMPT_FILE" ]]; then
  err "Prompt file not found: $PROMPT_FILE"; exit 1
fi
if [[ ! -d "$PLUGIN_DIR" ]]; then
  err "Skills plugin dir not found: $PLUGIN_DIR, run setup.sh first"; exit 1
fi
if ! docker ps >/dev/null 2>&1; then
  err "No Docker permission, benchmark requires Docker"
  err "Run: sudo usermod -aG docker \$USER  then reopen tmux session"
  exit 1
fi
ok "Pre-flight checks passed"

# ---- Log file ----
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${BENCH}_$(date +%Y%m%d_%H%M%S).log"
info "Log will be saved to: $LOG_FILE"

# ---- Run benchmark ----
info "Starting $BENCH benchmark..."
info "(bypassPermissions mode runs automatically, takes a while)"
echo "------------------------------------------------------------"
cd "$REPO_DIR"
claude --plugin-dir "$PLUGIN_DIR" \
  --no-session-persistence \
  --permission-mode bypassPermissions \
  --tools default \
  -p "$(cat "$PROMPT_FILE")" 2>&1 | tee "$LOG_FILE"
echo "------------------------------------------------------------"
ok "$BENCH benchmark finished"
ok "Full log: $LOG_FILE"
