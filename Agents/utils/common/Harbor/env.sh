#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# Load shared site configuration (committed template; see config.env).
# Values set there take effect for all tools; anything left unset falls
# through to the public-safe defaults below. config.local.env (git-ignored) is
# sourced after and overrides it; keep real credentials there, not in config.env.
# Caller-provided environment wins over both files so a one-off override like
# BASE_URL=... ./run still applies: snapshot it now, re-apply after sourcing.
__caller_env="$(export -p)"
if [[ -f "$REPO_ROOT/config.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_ROOT/config.env"
  set +a
fi
if [[ -f "$REPO_ROOT/config.local.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$REPO_ROOT/config.local.env"
  set +a
fi
eval "$__caller_env"
unset __caller_env

AGENTS_DIR="${AGENTS_DIR:-$REPO_ROOT/Agents}"
TASKS_DIR="${TASKS_DIR:-$REPO_ROOT/Tasks}"
HARBOR_CLAUDE_CODE_DIR="${HARBOR_CLAUDE_CODE_DIR:-$AGENTS_DIR/Harbor-claude-code}"
HARBOR_OPENCODE_DIR="${HARBOR_OPENCODE_DIR:-$AGENTS_DIR/Harbor-opencode}"
WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"

RUN_ID="${RUN_ID:-$(date +%Y-%m-%d-%H%M)-harbor-tui}"
TOTAL_WORKERS="${TOTAL_WORKERS:-10}"
N_ATTEMPTS="${N_ATTEMPTS:-1}"
MAX_RETRIES="${MAX_RETRIES:-${TB_MAX_RETRIES:-2}}"
# AGENT selects the runner: claude-code (default) or opencode.
AGENT="${AGENT:-claude-code}"
MODEL="${MODEL:-${TB_MODEL:-minimax2.7}}"
# OpenCode requires provider/model for custom providers. Keep MODEL shared with
# claude-code, and only add this prefix when AGENT=opencode.
OPENCODE_PROVIDER="${OPENCODE_PROVIDER:-custom}"

HARBOR_ROOT="${HARBOR_ROOT:-/workspace/harbor}"
# Dataset selection:
#   DATASET_NAME: auto, seta, smith, terminalbench21, sweverify. auto infers from DATASET_PATH.
#   DATASET_PATH examples:
#     /workspace/seta-env/Harbor-Dataset
#     /workspace/harbor/datasets/swesmith
#     /workspace/terminal-bench-2-1/tasks
#     /workspace/swebench-verified
# TASK_SOURCE_FILE can override the built-in task list under Tasks/.
DATASET_NAME="${DATASET_NAME:-auto}"
DATASET_PATH="${DATASET_PATH:-${TB_PATH:-/workspace/seta-env/Harbor-Dataset}}"
METRIC_MODE="${METRIC_MODE:-auto}"

OUTPUT_ROOT="${OUTPUT_ROOT:-/workspace/runs}"
OUTPUT_PATH="${OUTPUT_PATH:-${OUTPUT_ROOT}/${RUN_ID}}"
TASK_SOURCE_FILE="${TASK_SOURCE_FILE:-}"
TASK_FILE="${TASK_FILE:-${OUTPUT_PATH}/tasks.txt}"
# Per-agent state so toggling AGENT between runs in the same OUTPUT_PATH
# cannot cross-contaminate queue/wheel/image state. TASK_FILE stays shared.
QUEUE_DIR="${QUEUE_DIR:-${OUTPUT_PATH}/queue/${AGENT}}"
RUNTIME_DIR="${RUNTIME_DIR:-${OUTPUT_PATH}/runtime/${AGENT}}"
LAYOUT_FILE="${LAYOUT_FILE:-${OUTPUT_PATH}/harbor-layout.kdl}"
JOBS_ROOT="${JOBS_ROOT:-${OUTPUT_PATH}/jobs/${AGENT}}"
HARBOR_ONLINE_ANALYSIS="${HARBOR_ONLINE_ANALYSIS:-0}"
HARBOR_ONLINE_ANALYSIS_POLL_INTERVAL="${HARBOR_ONLINE_ANALYSIS_POLL_INTERVAL:-1}"
HARBOR_ONLINE_ANALYSIS_DIR="${HARBOR_ONLINE_ANALYSIS_DIR:-${OUTPUT_PATH}/online-analysis}"
HARBOR_ONLINE_ANALYSIS_PID_FILE="${HARBOR_ONLINE_ANALYSIS_PID_FILE:-${RUNTIME_DIR}/online-rule-analyzer.pid}"
HARBOR_ONLINE_ANALYSIS_LOG_FILE="${HARBOR_ONLINE_ANALYSIS_LOG_FILE:-${RUNTIME_DIR}/online-rule-analyzer.log}"
HARBOR_EARLY_STOP="${HARBOR_EARLY_STOP:-0}"

API_KEY="${API_KEY:-${ANTHROPIC_AUTH_TOKEN:-xxx}}"
BASE_URL="${BASE_URL:-${ANTHROPIC_BASE_URL:-}}"
# Normalize to a versionless API root: callers may supply a value already ending
# in /v1, but the endpoints below append /v1 (or /v1/chat/completions), so strip
# one trailing /v1 to avoid doubling it.
if [[ -n "$BASE_URL" ]]; then
  BASE_URL="${BASE_URL%/}"
  BASE_URL="${BASE_URL%/v1}"
fi
TRACE_TO_OPIK="${TRACE_TO_OPIK:-true}"
OPIK_URL="${OPIK_URL:-}"
OPIK_URL_OVERRIDE="${OPIK_URL_OVERRIDE:-$OPIK_URL}"
OPIK_BASE="${OPIK_BASE:-${OPIK_URL_OVERRIDE%/api}}"
OPIK_MODE="${OPIK_MODE:-remote}"
# opik project name: [name]-[agent]-[harbor/terminal-bench]-[dataset]-[LLM]-[timestamp]
OPIK_PROJECT_NAME="${OPIK_PROJECT_NAME:-xxx-claude-harbor-seta-minimax2.7-$(date +%Y%m%d-%H%M%S)}"
# Some launch wrappers pass the placeholder literally. Do not forward that
# into task containers, otherwise Opik auth/config becomes invalid.
if [[ "${OPIK_API_KEY:-}" == '${OPIK_API_KEY}' ]]; then
  unset OPIK_API_KEY
fi
OPIK_API_KEY="${OPIK_API_KEY:-local-dev-key}"
OPIK_WORKSPACE="${OPIK_WORKSPACE:-default}"
CC_OPIK_DEBUG="${CC_OPIK_DEBUG:-true}"

CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-${TB_AK_VERSION:-2.1.90}}"
CLAUDE_CODE_TGZ_BASENAME="${CLAUDE_CODE_TGZ_BASENAME:-claude-code-${CLAUDE_CODE_VERSION}.tgz}"
LOCAL_WHEEL_DIR="${LOCAL_WHEEL_DIR:-/workspace/claude-opik-minimal/python-wheels}"
LOCAL_WHEEL_PORT="${LOCAL_WHEEL_PORT:-18765}"
LOCAL_WHEEL_PORT_ATTEMPTS="${LOCAL_WHEEL_PORT_ATTEMPTS:-3}"
LOCAL_WHEEL_HOST_IP="${LOCAL_WHEEL_HOST_IP:-}"
if [[ -z "${LOCAL_WHEEL_HOST_IP:-}" ]] && command -v ip >/dev/null 2>&1; then
  LOCAL_WHEEL_HOST_IP="$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n 1 || true)"
fi
if [[ -z "${LOCAL_WHEEL_HOST_IP:-}" ]] && command -v ip >/dev/null 2>&1; then
  LOCAL_WHEEL_HOST_IP="$(ip route 2>/dev/null | awk '/^default /{print $3; exit}' || true)"
fi
if [[ -z "${TB_LOCAL_WHEEL_SERVER_URL:-}" && -n "${LOCAL_WHEEL_HOST_IP:-}" ]]; then
  TB_LOCAL_WHEEL_SERVER_URL="http://${LOCAL_WHEEL_HOST_IP}:${LOCAL_WHEEL_PORT}"
fi
if [[ -z "${TB_LOCAL_CLAUDE_TGZ_URL:-}" && -n "${TB_LOCAL_WHEEL_SERVER_URL:-}" ]]; then
  TB_LOCAL_CLAUDE_TGZ_URL="${TB_LOCAL_WHEEL_SERVER_URL%/}/${CLAUDE_CODE_TGZ_BASENAME}"
fi
TB_REMOTE_WHEEL_SERVER_URLS="${TB_REMOTE_WHEEL_SERVER_URLS:-}"
EFFECTIVE_WHEEL_URL_FILE="${RUNTIME_DIR}/effective-wheel-url"
EFFECTIVE_CLAUDE_TGZ_URL_FILE="${RUNTIME_DIR}/effective-claude-tgz-url"
LOCAL_DEPS_LOG_FILE="${RUNTIME_DIR}/local-deps-prepare.log"
HARBOR_RUNNER_PREPARE="${HARBOR_RUNNER_PREPARE:-1}"
HARBOR_OPIK_BIN="${HARBOR_OPIK_BIN:-/root/.local/bin/opik}"
HARBOR_RUNNER_PREPARE_STATUS_FILE="${RUNTIME_DIR}/harbor-runner-prepare.status"
HARBOR_RUNNER_PREPARE_LOG_FILE="${RUNTIME_DIR}/harbor-runner-prepare.log"

# Harbor CLI compatibility aliases. Keep all defaults here so harboropik.sh and
# the zellij worker scripts cannot drift into different model/network settings.
TB_DATASET_GIT_URL="${TB_DATASET_GIT_URL:-https://huggingface.co/datasets/zai-org/terminal-bench-2-verified}"
TB_PATH="${TB_PATH:-$DATASET_PATH}"
TB_LIMIT="${TB_LIMIT:-}"
TB_RUNS="${TB_RUNS:-$N_ATTEMPTS}"
TB_AGENT="${TB_AGENT:-$AGENT}"
TB_AGENT_IMPORT_PATH="${TB_AGENT_IMPORT_PATH:-}"
TB_MODEL="${TB_MODEL:-$MODEL}"
if [[ "$AGENT" == "opencode" && "$TB_MODEL" != */* && -n "$OPENCODE_PROVIDER" ]]; then
  TB_MODEL="${OPENCODE_PROVIDER}/${TB_MODEL}"
fi
INCLUDE_TASKS="${INCLUDE_TASKS:-${TB_INCLUDE_TASKS:-}}"
TB_DRY_RUN="${TB_DRY_RUN:-0}"
TB_MIN_TEST="${TB_MIN_TEST:-0}"
TB_MIN_TEST_INCLUDE_TASK="${TB_MIN_TEST_INCLUDE_TASK:-fix-git}"
TB_N_CONCURRENT="${TB_N_CONCURRENT:-$TOTAL_WORKERS}"
TB_MAX_RETRIES="${TB_MAX_RETRIES:-$MAX_RETRIES}"
TB_RETRY_INCLUDE_EXCEPTIONS="${TB_RETRY_INCLUDE_EXCEPTIONS-}"
TB_RETRY_EXCLUDE_EXCEPTIONS="${TB_RETRY_EXCLUDE_EXCEPTIONS-RewardFileNotFoundError,RewardFileEmptyError,VerifierOutputParseError}"
TB_AK_MAX_TURNS="${TB_AK_MAX_TURNS:-}"
TB_DISALLOWED_TOOLS="${TB_DISALLOWED_TOOLS:-WebSearch WebFetch RemoteTrigger AskUserQuestion}"
TB_APPEND_SYSTEM_PROMPT="${TB_APPEND_SYSTEM_PROMPT:-Use English only for all reasoning, messages, filenames, and tool arguments. Use ASCII characters only unless reading existing non-ASCII file contents is strictly necessary.}"
TB_API_BASE="${TB_API_BASE:-${BASE_URL%/}/v1/chat/completions}"
if [[ -z "${TB_LLM_KWARGS:-}" ]]; then
  TB_LLM_KWARGS='{"api_key":"'"${API_KEY}"'","temperature":1.0}'
fi
TB_MAX_NEW_TOKENS="${TB_MAX_NEW_TOKENS:-65536}"
TB_MODEL_INFO="${TB_MODEL_INFO:-}"
if [[ -z "$TB_MODEL_INFO" ]]; then
  TB_MODEL_INFO='{"max_input_tokens":204800,"max_output_tokens":65536}'
fi
TB_ANTHROPIC_BASE_URL="${TB_ANTHROPIC_BASE_URL:-${BASE_URL%/}}"
TB_ANTHROPIC_AUTH_TOKEN="${TB_ANTHROPIC_AUTH_TOKEN:-$API_KEY}"
TB_CLAUDE_CODE_MAX_OUTPUT_TOKENS="${TB_CLAUDE_CODE_MAX_OUTPUT_TOKENS:-65536}"
TB_CLAUDE_CODE_DISABLE_AUTOUPDATER="${TB_CLAUDE_CODE_DISABLE_AUTOUPDATER:-1}"

# Advanced Claude Code model routing defaults. Most users only need MODEL; these
# are kept here so frontgate-style gateways can map primary/subagent models.
TB_ANTHROPIC_MODEL="${TB_ANTHROPIC_MODEL:-$MODEL}"
TB_ANTHROPIC_DEFAULT_OPUS_MODEL="${TB_ANTHROPIC_DEFAULT_OPUS_MODEL:-$MODEL}"
TB_ANTHROPIC_DEFAULT_SONNET_MODEL="${TB_ANTHROPIC_DEFAULT_SONNET_MODEL:-$MODEL}"
TB_ANTHROPIC_DEFAULT_HAIKU_MODEL="${TB_ANTHROPIC_DEFAULT_HAIKU_MODEL:-$MODEL}"
TB_CLAUDE_CODE_SUBAGENT_MODEL="${TB_CLAUDE_CODE_SUBAGENT_MODEL:-$MODEL}"
TB_CLAUDE_CODE_EFFORT_LEVEL="${TB_CLAUDE_CODE_EFFORT_LEVEL:-max}"

TB_TIMEOUT_MULTIPLIER="${TB_TIMEOUT_MULTIPLIER:-3.0}"
# Overrides only the agent execution timeout. Leave empty to use TB_TIMEOUT_MULTIPLIER.
TB_AGENT_TIMEOUT_MULTIPLIER="${TB_AGENT_TIMEOUT_MULTIPLIER:-}"
TB_AGENT_SETUP_TIMEOUT_MULTIPLIER="${TB_AGENT_SETUP_TIMEOUT_MULTIPLIER:-20}"
# Set to 1 only when Harbor prebuilt task images fail to pull from registry mirrors;
# this bypasses prebuilt pulls and builds from each task's local Dockerfile instead.
TB_FORCE_BUILD="${TB_FORCE_BUILD:-0}"
TB_DEBUG="${TB_DEBUG:-0}"
TB_CC_OPIK_ENABLE_HOOK="${TB_CC_OPIK_ENABLE_HOOK:-1}"
TRACE_PLUGIN_SOURCE_DIR="${TRACE_PLUGIN_SOURCE_DIR:-$REPO_ROOT/third_party/sii-opik-plugin}"
TRACE_PLUGIN_CLAUDE_HOOK_SOURCE="${TRACE_PLUGIN_CLAUDE_HOOK_SOURCE:-$TRACE_PLUGIN_SOURCE_DIR/src/sii_opik_plugin/claude_code/claude_realtime_trace.py}"
TRACE_PLUGIN_OPENCODE_PLUGIN_SOURCE="${TRACE_PLUGIN_OPENCODE_PLUGIN_SOURCE:-$TRACE_PLUGIN_SOURCE_DIR/harness/opencode/opik-trace.ts}"
TRACE_PLUGIN_OPENCODE_HOOK_SOURCE="${TRACE_PLUGIN_OPENCODE_HOOK_SOURCE:-$TRACE_PLUGIN_SOURCE_DIR/src/sii_opik_plugin/opencode/opencode_realtime_trace.py}"
TB_CC_HOOK_SOURCE="${TB_CC_HOOK_SOURCE:-$TRACE_PLUGIN_CLAUDE_HOOK_SOURCE}"
TB_CC_HOOK_MOUNT_PATH="${TB_CC_HOOK_MOUNT_PATH:-/opt/tb-opik/claude_realtime_trace.py}"
TB_CC_CLAUDE_TGZ_SOURCE="${TB_CC_CLAUDE_TGZ_SOURCE:-${LOCAL_WHEEL_DIR}/${CLAUDE_CODE_TGZ_BASENAME}}"
TB_CC_CLAUDE_TGZ_MOUNT_PATH="${TB_CC_CLAUDE_TGZ_MOUNT_PATH:-/opt/tb-opik/claude-code.tgz}"
TB_CC_PY_WHEEL_DIR_SOURCE="${TB_CC_PY_WHEEL_DIR_SOURCE:-$LOCAL_WHEEL_DIR}"
TB_CC_PY_WHEEL_DIR_MOUNT_PATH="${TB_CC_PY_WHEEL_DIR_MOUNT_PATH:-/opt/tb-opik/python-wheels}"
TB_CC_NPM_CACHE_MOUNT_PATH="${TB_CC_NPM_CACHE_MOUNT_PATH:-${TB_CC_PY_WHEEL_DIR_MOUNT_PATH}/npm-cache}"
TB_VERIFIER_UV_HOME="${TB_VERIFIER_UV_HOME:-}"
TB_VERIFIER_UV_BIN_DIR_MOUNT_PATH="${TB_VERIFIER_UV_BIN_DIR_MOUNT_PATH:-/opt/tb-uv-backup/bin}"
TB_TRACE_TO_OPIK="${TB_TRACE_TO_OPIK:-$TRACE_TO_OPIK}"
TB_CC_OPIK_DEBUG="${TB_CC_OPIK_DEBUG:-$CC_OPIK_DEBUG}"
TB_CC_OPIK_INSTALL_DEPS="${TB_CC_OPIK_INSTALL_DEPS:-true}"
TB_PIP_INDEX_URL="${TB_PIP_INDEX_URL:-${PIP_INDEX_URL:-https://pypi.org/simple/}}"
TB_PIP_EXTRA_INDEX_URL="${TB_PIP_EXTRA_INDEX_URL:-${PIP_EXTRA_INDEX_URL:-}}"
TB_PIP_TRUSTED_HOST="${TB_PIP_TRUSTED_HOST:-${PIP_TRUSTED_HOST:-}}"
TB_UV_INDEX_URL="${TB_UV_INDEX_URL:-$TB_PIP_INDEX_URL}"
TB_UV_DEFAULT_INDEX="${TB_UV_DEFAULT_INDEX:-$TB_UV_INDEX_URL}"
TB_PIP_DEFAULT_TIMEOUT="${TB_PIP_DEFAULT_TIMEOUT:-120}"
TB_PIP_RETRIES="${TB_PIP_RETRIES:-10}"
OPIK_REPO_DIR="${OPIK_REPO_DIR:-$HOME/sii-opik}"
COMPOSE_DIR="${COMPOSE_DIR:-$OPIK_REPO_DIR/deployment/docker-compose}"
TB_SKIP_DOCKERHUB_PREFLIGHT="${TB_SKIP_DOCKERHUB_PREFLIGHT:-0}"
TB_DOCKERHUB_CHECK_TIMEOUT="${TB_DOCKERHUB_CHECK_TIMEOUT:-8}"
TB_DOCKERHUB_PREFLIGHT_STRICT="${TB_DOCKERHUB_PREFLIGHT_STRICT:-0}"
SMITH_GENERATE_IF_MISSING="${SMITH_GENERATE_IF_MISSING:-1}"
SMITH_ADAPTER_DIR="${SMITH_ADAPTER_DIR:-$HARBOR_ROOT/adapters/swesmith}"
FIX_GIT_IMAGE_NAME="${FIX_GIT_IMAGE_NAME:-xiangyangli/fix-git:20260204}"
FIX_GIT_WARM_LABEL="${FIX_GIT_WARM_LABEL:-io.codex.prewarmed}"

# ── opencode agent ────────────────────────────────────────────────────────────
OPENCODE_VERSION="${OPENCODE_VERSION:-latest}"
OPENCODE_TGZ_BASENAME="${OPENCODE_TGZ_BASENAME:-opencode-ai-${OPENCODE_VERSION}.tgz}"
OPENCODE_LINUX_X64_TGZ_BASENAME="${OPENCODE_LINUX_X64_TGZ_BASENAME:-opencode-linux-x64-${OPENCODE_VERSION}.tgz}"
OPENCODE_CONFIG_CONTENT="${OPENCODE_CONFIG_CONTENT:-}"
if [[ "$AGENT" == "opencode" && -z "$OPENCODE_CONFIG_CONTENT" && "${TB_MODEL%%/*}" == "custom" ]]; then
  # OpenCode's built-in minimax provider ignores our gateway BASE_URL and calls
  # api.minimax.io directly. Use an OpenAI-compatible custom provider by default.
  OPENCODE_CONFIG_CONTENT="$(
    python3 - "$BASE_URL" "$API_KEY" "${TB_MODEL#*/}" <<'PY'
import json
import sys

base_url = sys.argv[1].rstrip("/") + "/v1"
api_key = sys.argv[2]
model = sys.argv[3]
print(json.dumps({
    "provider": {
        "custom": {
            "npm": "@ai-sdk/openai-compatible",
            "options": {
                "baseURL": base_url,
                "apiKey": api_key,
            },
            "models": {
                model: {"name": model},
            },
        },
    },
}, separators=(",", ":")))
PY
  )"
fi

NEXT_INDEX_FILE="${QUEUE_DIR}/next_index"
LOCK_FILE="${QUEUE_DIR}/.queue.lock"
WORKERS_READY_FILE="${RUNTIME_DIR}/workers.ready"
WORKERS_FAILED_FILE="${RUNTIME_DIR}/workers.failed"

export SCRIPT_DIR REPO_ROOT AGENTS_DIR TASKS_DIR HARBOR_CLAUDE_CODE_DIR HARBOR_OPENCODE_DIR WORKSPACE_DIR RUN_ID TOTAL_WORKERS N_ATTEMPTS MODEL AGENT MAX_RETRIES
export HARBOR_ROOT DATASET_PATH DATASET_NAME METRIC_MODE OUTPUT_ROOT OUTPUT_PATH TASK_SOURCE_FILE TASK_FILE QUEUE_DIR RUNTIME_DIR LAYOUT_FILE JOBS_ROOT
export HARBOR_ONLINE_ANALYSIS HARBOR_ONLINE_ANALYSIS_POLL_INTERVAL HARBOR_ONLINE_ANALYSIS_DIR HARBOR_ONLINE_ANALYSIS_PID_FILE HARBOR_ONLINE_ANALYSIS_LOG_FILE HARBOR_EARLY_STOP
export API_KEY BASE_URL TRACE_TO_OPIK OPIK_URL OPIK_URL_OVERRIDE OPIK_BASE OPIK_MODE OPIK_PROJECT_NAME OPIK_API_KEY OPIK_WORKSPACE CC_OPIK_DEBUG
export CLAUDE_CODE_VERSION CLAUDE_CODE_TGZ_BASENAME LOCAL_WHEEL_DIR LOCAL_WHEEL_PORT LOCAL_WHEEL_PORT_ATTEMPTS LOCAL_WHEEL_HOST_IP
export TB_LOCAL_WHEEL_SERVER_URL TB_LOCAL_CLAUDE_TGZ_URL TB_REMOTE_WHEEL_SERVER_URLS EFFECTIVE_WHEEL_URL_FILE EFFECTIVE_CLAUDE_TGZ_URL_FILE LOCAL_DEPS_LOG_FILE HARBOR_RUNNER_PREPARE HARBOR_OPIK_BIN HARBOR_RUNNER_PREPARE_STATUS_FILE HARBOR_RUNNER_PREPARE_LOG_FILE
export TB_DATASET_GIT_URL TB_PATH TB_LIMIT TB_RUNS TB_AGENT TB_AGENT_IMPORT_PATH TB_MODEL INCLUDE_TASKS TB_DRY_RUN TB_MIN_TEST TB_MIN_TEST_INCLUDE_TASK
export TB_N_CONCURRENT TB_MAX_RETRIES TB_RETRY_INCLUDE_EXCEPTIONS TB_RETRY_EXCLUDE_EXCEPTIONS TB_AK_MAX_TURNS TB_DISALLOWED_TOOLS TB_APPEND_SYSTEM_PROMPT
export TB_API_BASE TB_LLM_KWARGS TB_MAX_NEW_TOKENS TB_MODEL_INFO TB_ANTHROPIC_BASE_URL TB_ANTHROPIC_AUTH_TOKEN TB_CLAUDE_CODE_MAX_OUTPUT_TOKENS
export TB_CLAUDE_CODE_DISABLE_AUTOUPDATER TB_ANTHROPIC_MODEL TB_ANTHROPIC_DEFAULT_OPUS_MODEL TB_ANTHROPIC_DEFAULT_SONNET_MODEL TB_ANTHROPIC_DEFAULT_HAIKU_MODEL TB_CLAUDE_CODE_SUBAGENT_MODEL TB_CLAUDE_CODE_EFFORT_LEVEL
export TB_TIMEOUT_MULTIPLIER TB_AGENT_TIMEOUT_MULTIPLIER TB_AGENT_SETUP_TIMEOUT_MULTIPLIER TB_FORCE_BUILD TB_DEBUG TRACE_PLUGIN_SOURCE_DIR TRACE_PLUGIN_CLAUDE_HOOK_SOURCE TRACE_PLUGIN_OPENCODE_PLUGIN_SOURCE TRACE_PLUGIN_OPENCODE_HOOK_SOURCE TB_CC_OPIK_ENABLE_HOOK
export TB_CC_HOOK_SOURCE TB_CC_HOOK_MOUNT_PATH TB_CC_CLAUDE_TGZ_SOURCE TB_CC_CLAUDE_TGZ_MOUNT_PATH
export TB_CC_PY_WHEEL_DIR_SOURCE TB_CC_PY_WHEEL_DIR_MOUNT_PATH TB_CC_NPM_CACHE_MOUNT_PATH TB_VERIFIER_UV_HOME TB_VERIFIER_UV_BIN_DIR_MOUNT_PATH TB_TRACE_TO_OPIK TB_CC_OPIK_DEBUG TB_CC_OPIK_INSTALL_DEPS
export TB_PIP_INDEX_URL TB_PIP_EXTRA_INDEX_URL TB_PIP_TRUSTED_HOST TB_UV_INDEX_URL TB_UV_DEFAULT_INDEX TB_PIP_DEFAULT_TIMEOUT TB_PIP_RETRIES
export OPIK_REPO_DIR COMPOSE_DIR TB_SKIP_DOCKERHUB_PREFLIGHT TB_DOCKERHUB_CHECK_TIMEOUT TB_DOCKERHUB_PREFLIGHT_STRICT SMITH_GENERATE_IF_MISSING SMITH_ADAPTER_DIR FIX_GIT_IMAGE_NAME FIX_GIT_WARM_LABEL
export OPENCODE_PROVIDER OPENCODE_VERSION OPENCODE_TGZ_BASENAME OPENCODE_LINUX_X64_TGZ_BASENAME OPENCODE_CONFIG_CONTENT
export NEXT_INDEX_FILE LOCK_FILE WORKERS_READY_FILE WORKERS_FAILED_FILE
export PATH="/opt/tb-venv/bin:${PATH}"

harbor_init_run_dirs() {
  mkdir -p "$OUTPUT_PATH" "$QUEUE_DIR" "$RUNTIME_DIR/worker-logs" "$JOBS_ROOT"
  touch "$QUEUE_DIR/done.txt" "$QUEUE_DIR/failed.txt"
}

harbor_agent_is_opencode() {
  [[ "$AGENT" == "opencode" ]]
}

harbor_agent_is_claude_code() {
  [[ "$AGENT" == "claude-code" ]]
}

harbor_validate_agent() {
  case "$AGENT" in
    claude-code|opencode) ;;
    *)
      echo "[ERROR] AGENT must be claude-code or opencode, got: $AGENT" >&2
      exit 1
      ;;
  esac

  if harbor_agent_is_opencode; then
    if [[ -z "$OPENCODE_CONFIG_CONTENT" ]]; then
      echo "[WARN] AGENT=opencode but OPENCODE_CONFIG_CONTENT is empty;" >&2
      echo "[WARN] opencode will fall back to ANTHROPIC_* env if provided." >&2
    fi
  fi
}

harbor_reset_run_state() {
  if [[ -f "$HARBOR_ONLINE_ANALYSIS_PID_FILE" ]]; then
    local online_pid
    online_pid="$(cat "$HARBOR_ONLINE_ANALYSIS_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$online_pid" ]]; then
      kill "$online_pid" >/dev/null 2>&1 || true
    fi
  fi
  rm -f "$QUEUE_DIR"/worker-*.current "$LOCK_FILE" "$WORKERS_READY_FILE" "$WORKERS_FAILED_FILE"
  rm -f "$NEXT_INDEX_FILE"
  rm -f "$HARBOR_ONLINE_ANALYSIS_PID_FILE" "$HARBOR_ONLINE_ANALYSIS_LOG_FILE"
  rm -f "$HARBOR_ONLINE_ANALYSIS_DIR/environment-events.jsonl" "$HARBOR_ONLINE_ANALYSIS_DIR/environment-summary.json"
  : > "$QUEUE_DIR/done.txt"
  : > "$QUEUE_DIR/failed.txt"
}

harbor_generate_task_file() {
  local source_file
  source_file="$(harbor_task_source_file || true)"
  if [[ -n "$source_file" ]]; then
    cp "$source_file" "$TASK_FILE"
    return 0
  fi

  if [[ ! -d "$DATASET_PATH" ]]; then
    echo "DATASET_PATH not found: $DATASET_PATH" >&2
    return 1
  fi

  # Harbor local datasets are one task per top-level directory.  SWE-smith uses
  # instruction.md, while SETA/Terminal-Bench tasks use task.yaml.  Keep this
  # scan format-neutral so the same zellij runner can handle both datasets.
  python3 - "$DATASET_PATH" "$TASK_FILE" <<'PY'
import sys
from pathlib import Path

dataset = Path(sys.argv[1])
task_file = Path(sys.argv[2])
tasks = []
for task_dir in dataset.iterdir():
    if not task_dir.is_dir():
        continue
    instruction = task_dir / "instruction.md"
    task_yaml = task_dir / "task.yaml"
    if instruction.is_file():
        try:
            if instruction.read_text(errors="ignore").strip():
                tasks.append(task_dir.name)
        except OSError:
            continue
    elif task_yaml.is_file():
        tasks.append(task_dir.name)
task_file.write_text("\n".join(sorted(tasks)) + ("\n" if tasks else ""))
PY
}

harbor_dataset_kind() {
  if [[ "$DATASET_NAME" != "auto" ]]; then
    printf '%s\n' "$DATASET_NAME"
    return 0
  fi
  case "$DATASET_PATH" in
    */seta-env|*/seta-env/Dataset|*seta*) printf 'seta\n' ;;
    *swesmith*|*smith*) printf 'smith\n' ;;
    *terminal-bench-2-1*|*terminalbench21*|*terminal-bench21*) printf 'terminalbench21\n' ;;
    *swebench-verified*|*sweverify*|*swe-verify*) printf 'sweverify\n' ;;
    *) printf 'harbor\n' ;;
  esac
}

harbor_builtin_task_file() {
  case "$(harbor_dataset_kind)" in
    seta) printf '%s\n' "$TASKS_DIR/SETA/harbor_tasks.txt" ;;
    smith) printf '%s\n' "$TASKS_DIR/SWE-smith/harbor_tasks.txt" ;;
    terminalbench21) printf '%s\n' "$TASKS_DIR/Terminal-bench-2/harbor_terminalbench21_tasks.txt" ;;
    sweverify) printf '%s\n' "$TASKS_DIR/SWE-verify/harbor_tasks.txt" ;;
    *) return 1 ;;
  esac
}

harbor_task_source_file() {
  if [[ -n "${TASK_SOURCE_FILE:-}" ]]; then
    if [[ ! -s "$TASK_SOURCE_FILE" ]]; then
      echo "TASK_SOURCE_FILE not found or empty: $TASK_SOURCE_FILE" >&2
      return 1
    fi
    printf '%s\n' "$TASK_SOURCE_FILE"
    return 0
  fi

  local builtin
  builtin="$(harbor_builtin_task_file || true)"
  if [[ -n "$builtin" && -s "$builtin" ]]; then
    printf '%s\n' "$builtin"
    return 0
  fi

  if [[ -n "$builtin" ]]; then
    echo "[WARN] built-in task list missing or empty: $builtin; falling back to DATASET_PATH scan" >&2
  fi
  return 1
}

harbor_metric_mode() {
  if [[ "$METRIC_MODE" != "auto" ]]; then
    printf '%s\n' "$METRIC_MODE"
    return 0
  fi
  if [[ "$(harbor_dataset_kind)" == "seta" || "$(harbor_dataset_kind)" == "terminalbench21" || "$(harbor_dataset_kind)" == "sweverify" ]]; then
    printf 'success\n'
  else
    printf 'reward\n'
  fi
}

harbor_prepare_task_file() {
  mkdir -p "$(dirname "$TASK_FILE")"
  if [[ "${RESET_RUN:-0}" == "1" || ! -s "$TASK_FILE" ]]; then
    harbor_generate_task_file
  fi
  if [[ ! -f "$NEXT_INDEX_FILE" ]]; then
    echo 1 > "$NEXT_INDEX_FILE"
  fi
}

harbor_task_count() {
  if [[ -f "$TASK_FILE" ]]; then
    wc -l < "$TASK_FILE" | tr -d ' '
  else
    echo 0
  fi
}

harbor_ensure_dataset() {
  local dataset_kind
  dataset_kind="$(harbor_dataset_kind)"

  if [[ -d "$DATASET_PATH" ]] && [[ -n "$(find -L "$DATASET_PATH" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)" ]]; then
    return 0
  fi

  if [[ "$dataset_kind" == "smith" && "$SMITH_GENERATE_IF_MISSING" == "1" ]]; then
    if [[ ! -d "$SMITH_ADAPTER_DIR" ]]; then
      echo "smith dataset missing and adapter not found: $SMITH_ADAPTER_DIR" >&2
      return 1
    fi
    echo "[INFO] smith dataset not found at $DATASET_PATH, generating with $SMITH_ADAPTER_DIR"
    (
      cd "$SMITH_ADAPTER_DIR"
      uv sync
      uv run run_adapter.py --limit 0
    )
  fi

  if [[ ! -d "$DATASET_PATH" ]]; then
    echo "DATASET_PATH not found: $DATASET_PATH" >&2
    return 1
  fi
}

harbor_pick_task() {
  exec 9>"$LOCK_FILE"
  flock 9

  local total idx task_name
  total="$(harbor_task_count)"
  idx="$(cat "$NEXT_INDEX_FILE" 2>/dev/null || echo 1)"
  if [[ -z "$idx" || "$idx" -gt "$total" ]]; then
    flock -u 9
    return 1
  fi

  task_name="$(sed -n "${idx}p" "$TASK_FILE" | tr -d '\r')"
  echo $((idx + 1)) > "$NEXT_INDEX_FILE"
  flock -u 9

  [[ -n "$task_name" ]] || return 1
  printf '%s\t%s\n' "$idx" "$task_name"
}

harbor_wait_for_workers_ready() {
  while true; do
    if [[ -f "$WORKERS_READY_FILE" ]]; then
      harbor_apply_effective_wheel_source
      return 0
    fi
    [[ -f "$WORKERS_FAILED_FILE" ]] && return 1
    sleep 1
  done
}

harbor_ensure_local_wheels_server() {
  mkdir -p "$RUNTIME_DIR"
  local pid_file="${RUNTIME_DIR}/local-wheel-http.pid"
  local log_file="${RUNTIME_DIR}/local-wheel-http.log"
  local port pid attempt last_port

  [[ -d "$LOCAL_WHEEL_DIR" ]] || return 0

  last_port=$((LOCAL_WHEEL_PORT + LOCAL_WHEEL_PORT_ATTEMPTS - 1))
  for port in $(seq "$LOCAL_WHEEL_PORT" "$last_port"); do
    export TB_LOCAL_WHEEL_SERVER_URL="http://${LOCAL_WHEEL_HOST_IP}:${port}"
    export TB_LOCAL_CLAUDE_TGZ_URL="${TB_LOCAL_WHEEL_SERVER_URL%/}/${CLAUDE_CODE_TGZ_BASENAME}"
    local agent_tgz="$CLAUDE_CODE_TGZ_BASENAME"
    if harbor_agent_is_opencode; then
      agent_tgz="$OPENCODE_TGZ_BASENAME"
    fi

    # Treat wheel servers without the selected agent tgz as incomplete.
    local urls=("${TB_LOCAL_WHEEL_SERVER_URL%/}/manifest.txt" "${TB_LOCAL_WHEEL_SERVER_URL%/}/${agent_tgz}")
    if harbor_agent_is_opencode; then
      urls+=("${TB_LOCAL_WHEEL_SERVER_URL%/}/${OPENCODE_LINUX_X64_TGZ_BASENAME}")
    else
      urls+=("${TB_LOCAL_WHEEL_SERVER_URL%/}/npm-cache-ready")
    fi

    # Avoid probing a broad range of ports. Start on the preferred port first;
    # only if binding fails do a narrow readiness check to see whether another
    # monitor already owns a compatible wheel server on that exact port.
    nohup python3 -m http.server "$port" --directory "$LOCAL_WHEEL_DIR" \
      >"$log_file.${port}" 2>&1 &
    pid="$!"
    sleep 1

    local ready=1
    local url
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      ready=1
      for url in "${urls[@]}"; do
        if ! harbor_url_is_reachable "$url"; then
          ready=0
          break
        fi
      done
      if [[ "$ready" == "1" ]]; then
        echo "$port" > "${RUNTIME_DIR}/local-wheel-http.port"
        return 0
      fi
      continue
    fi

    for url in "${urls[@]}"; do
      if ! harbor_url_is_reachable "$url"; then
        ready=0
        break
      fi
    done
    if [[ "$ready" == "1" ]]; then
      echo "$pid" > "$pid_file"
      echo "$port" > "${RUNTIME_DIR}/local-wheel-http.port"
      return 0
    fi
    kill "$pid" >/dev/null 2>&1 || true
  done

  echo "failed to start a matching local wheel HTTP server in ${LOCAL_WHEEL_PORT_ATTEMPTS} attempts" >&2
  return 1
}

harbor_url_is_reachable() {
  local url="$1"
  TARGET_URL="$url" python3 - <<'PY'
import os
import urllib.request
try:
    with urllib.request.urlopen(os.environ["TARGET_URL"], timeout=2) as response:
        raise SystemExit(0 if response.status < 400 else 1)
except Exception:
    raise SystemExit(1)
PY
}

harbor_manifest_url_ready() {
  local url="$1"
  TARGET_URL="$url" python3 - <<'PY'
import os
import urllib.request
try:
    with urllib.request.urlopen(os.environ["TARGET_URL"], timeout=2) as response:
        content = response.read(1024 * 64).decode("utf-8", "replace")
    raise SystemExit(0 if "cache_schema=3\n" in content else 1)
except Exception:
    raise SystemExit(1)
PY
}

harbor_gzip_file_ready() {
  local path="$1"
  [[ -f "$path" ]] && gzip -t "$path" >/dev/null 2>&1
}

harbor_tar_file_ready() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  python3 - "$path" <<'PY' >/dev/null 2>&1
import sys
import tarfile

with tarfile.open(sys.argv[1]) as archive:
    archive.getmembers()
PY
}

harbor_local_cache_ready() {
  [[ -f "$LOCAL_WHEEL_DIR/manifest.txt" ]] \
    && grep -qx 'cache_schema=3' "$LOCAL_WHEEL_DIR/manifest.txt" \
    && [[ "$(find "$LOCAL_WHEEL_DIR" -maxdepth 1 -name 'opik-*.whl' -type f | wc -l | tr -d ' ')" == "1" ]] \
    && [[ -f "$LOCAL_WHEEL_DIR/get-pip.py" ]] \
    && harbor_tar_file_ready "$LOCAL_WHEEL_DIR/node-runtime.tar.xz" \
    && harbor_gzip_file_ready "$LOCAL_WHEEL_DIR/python3.12-runtime.tar.gz" \
    && {
      if harbor_agent_is_opencode; then
        harbor_gzip_file_ready "$LOCAL_WHEEL_DIR/${OPENCODE_TGZ_BASENAME}" \
          && harbor_gzip_file_ready "$LOCAL_WHEEL_DIR/${OPENCODE_LINUX_X64_TGZ_BASENAME}"
      else
        [[ -f "$LOCAL_WHEEL_DIR/${CLAUDE_CODE_TGZ_BASENAME}" ]] \
          && [[ -d "$LOCAL_WHEEL_DIR/npm-cache/_cacache" ]] \
          && [[ -f "$LOCAL_WHEEL_DIR/npm-cache-ready" ]] \
          && grep -qx "claude_npm_cache_version=${CLAUDE_CODE_VERSION}" "$LOCAL_WHEEL_DIR/manifest.txt"
      fi
    }
}

harbor_pick_remote_wheel_url() {
  local candidates=()
  local candidate
  if [[ -n "${TB_REMOTE_WHEEL_SERVER_URLS:-}" ]]; then
    IFS=',' read -r -a candidates <<< "$TB_REMOTE_WHEEL_SERVER_URLS"
  elif [[ -n "${TB_LOCAL_WHEEL_SERVER_URL:-}" ]]; then
    candidates=("$TB_LOCAL_WHEEL_SERVER_URL")
  fi

  for candidate in "${candidates[@]}"; do
    candidate="${candidate%% }"
    candidate="${candidate## }"
    [[ -n "${candidate:-}" ]] || continue
    local agent_tgz="$CLAUDE_CODE_TGZ_BASENAME"
    if harbor_agent_is_opencode; then
      agent_tgz="$OPENCODE_TGZ_BASENAME"
    fi
    local urls=("${candidate%/}/${agent_tgz}")
    if harbor_agent_is_opencode; then
      urls+=("${candidate%/}/${OPENCODE_LINUX_X64_TGZ_BASENAME}")
    else
      urls+=("${candidate%/}/npm-cache-ready")
    fi
    local ready=1
    local url
    if ! harbor_manifest_url_ready "${candidate%/}/manifest.txt"; then
      ready=0
    fi
    for url in "${urls[@]}"; do
      if ! harbor_url_is_reachable "$url"; then
        ready=0
        break
      fi
    done
    if [[ "$ready" == "1" ]]; then
      printf '%s\n' "${candidate%/}"
      return 0
    fi
  done
  return 1
}

harbor_write_effective_wheel_source() {
  local wheel_url="$1"
  printf '%s\n' "$wheel_url" > "$EFFECTIVE_WHEEL_URL_FILE"
  printf '%s\n' "${wheel_url%/}/${CLAUDE_CODE_TGZ_BASENAME}" > "$EFFECTIVE_CLAUDE_TGZ_URL_FILE"
  export TB_LOCAL_WHEEL_SERVER_URL="$wheel_url"
  export TB_LOCAL_CLAUDE_TGZ_URL="${wheel_url%/}/${CLAUDE_CODE_TGZ_BASENAME}"
}

harbor_apply_effective_wheel_source() {
  if [[ -f "$EFFECTIVE_WHEEL_URL_FILE" ]]; then
    export TB_LOCAL_WHEEL_SERVER_URL="$(cat "$EFFECTIVE_WHEEL_URL_FILE")"
  fi
  if [[ -f "$EFFECTIVE_CLAUDE_TGZ_URL_FILE" ]]; then
    export TB_LOCAL_CLAUDE_TGZ_URL="$(cat "$EFFECTIVE_CLAUDE_TGZ_URL_FILE")"
  elif [[ -n "${TB_LOCAL_WHEEL_SERVER_URL:-}" ]]; then
    export TB_LOCAL_CLAUDE_TGZ_URL="${TB_LOCAL_WHEEL_SERVER_URL%/}/${CLAUDE_CODE_TGZ_BASENAME}"
  fi
}

harbor_prepare_or_select_wheels() {
  mkdir -p "$RUNTIME_DIR"
  local status_file="${RUNTIME_DIR}/local-deps-prepare.status"
  rm -f "$WORKERS_READY_FILE" "$WORKERS_FAILED_FILE" "$EFFECTIVE_WHEEL_URL_FILE" "$EFFECTIVE_CLAUDE_TGZ_URL_FILE" "$HARBOR_RUNNER_PREPARE_STATUS_FILE"
  : > "$LOCAL_DEPS_LOG_FILE"
  echo "checking" > "$status_file"

  if harbor_local_cache_ready; then
    echo "using local wheel cache"
    harbor_ensure_local_wheels_server
    harbor_write_effective_wheel_source "$TB_LOCAL_WHEEL_SERVER_URL"
    echo "done" > "$status_file"
    harbor_mark_workers_ready
    return $?
  fi

  local remote_url
  remote_url="$(harbor_pick_remote_wheel_url || true)"
  if [[ -n "${remote_url:-}" ]]; then
    echo "using remote wheel cache: $remote_url"
    harbor_write_effective_wheel_source "$remote_url"
    echo "remote" > "$status_file"
    harbor_mark_workers_ready
    return $?
  fi

  echo "preparing" > "$status_file"
  echo "local cache missing; downloading dependency cache..."
  local prepare_opencode_cache=0
  if harbor_agent_is_opencode; then
    prepare_opencode_cache=1
  fi
  if (cd "$SCRIPT_DIR" && WHEEL_DIR="$LOCAL_WHEEL_DIR" CACHE_SCHEMA=3 CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" CLAUDE_CODE_TGZ_BASENAME="$CLAUDE_CODE_TGZ_BASENAME" PREPARE_OPENCODE_CACHE="$prepare_opencode_cache" OPENCODE_VERSION="$OPENCODE_VERSION" OPENCODE_TGZ_BASENAME="$OPENCODE_TGZ_BASENAME" OPENCODE_LINUX_X64_TGZ_BASENAME="$OPENCODE_LINUX_X64_TGZ_BASENAME" ./prepare_local_deps.sh 2>&1 | tee -a "$LOCAL_DEPS_LOG_FILE"); then
    harbor_ensure_local_wheels_server
    harbor_write_effective_wheel_source "$TB_LOCAL_WHEEL_SERVER_URL"
    echo "done" > "$status_file"
    harbor_mark_workers_ready
    return $?
  fi

  echo "failed" > "$status_file"
  touch "$WORKERS_FAILED_FILE"
  return 1
}

harbor_prepare_agent_runtime() {
  if harbor_agent_is_opencode; then
    if ! harbor_prepare_or_select_wheels; then
      echo "failed to prepare local dependency cache" >&2
      touch "$WORKERS_FAILED_FILE"
      return 1
    fi
    return 0
  fi

  if ! harbor_prepare_or_select_wheels; then
    echo "failed to prepare local dependency cache" >&2
    touch "$WORKERS_FAILED_FILE"
    return 1
  fi
}

harbor_prepare_runner_cli() {
  python3 "$SCRIPT_DIR/harbor_prepare_runner_cli.py"
}

harbor_mark_workers_ready() {
  if harbor_prepare_runner_cli; then
    touch "$WORKERS_READY_FILE"
    return 0
  fi
  return 1
}
