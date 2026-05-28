#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

WORKER_ID="${1:?worker id required}"
harbor_init_run_dirs
if ! harbor_wait_for_workers_ready; then
  echo "worker startup aborted: monitor failed readiness checks" >&2
  exit 1
fi
if harbor_local_cache_ready; then
  harbor_ensure_local_wheels_server
fi

CURRENT_FILE="$QUEUE_DIR/worker-${WORKER_ID}.current"
WORKER_LOG="$RUNTIME_DIR/worker-logs/worker-${WORKER_ID}.log"
CLAUDE_TAIL_PID=""

cleanup() {
  rm -f "$CURRENT_FILE"
  if [[ -n "${CLAUDE_TAIL_PID:-}" ]]; then
    kill "$CLAUDE_TAIL_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log_msg() {
  local msg="$1"
  printf '[%s] [worker-%s] %s\n' "$(date '+%F %T')" "$WORKER_ID" "$msg" | tee -a "$WORKER_LOG"
}

safe_name() {
  printf '%s' "$1" | tr '/[:space:]' '___' | tr -cd 'A-Za-z0-9._-'
}

find_latest_trial_result() {
  python3 "$SCRIPT_DIR/harbor_worker_utils.py" latest-result "$1"
}

summarize_result() {
  python3 "$SCRIPT_DIR/harbor_worker_utils.py" summarize-result "$1"
}

stream_claude_log() {
  python3 "$SCRIPT_DIR/harbor_worker_utils.py" stream-claude-log "$1"
}

find_trial_logs_dir() {
  local result_file="$1"
  local result_dir
  result_dir="$(dirname "$result_file")"
  if [[ -d "$result_dir/logs" ]]; then
    printf '%s\n' "$result_dir/logs"
    return 0
  fi
  if [[ -f "$result_dir/agent/opencode.txt" ]]; then
    # Harbor pulls EnvironmentPaths.agent_dir to trial/agent. OpenCode stores
    # replayable hook backups there so timeout finalization can use the normal
    # session_end path instead of a simplified fallback trace.
    printf '%s\n' "$result_dir/agent"
    return 0
  fi
  if [[ -d "$result_dir/agent/sessions" ]]; then
    # Claude Code backups live under trial/agent/sessions, but the Claude replay
    # helper expects the trial root and reads agent/sessions/... itself.
    printf '%s\n' "$result_dir"
    return 0
  fi
  find "$result_dir" -mindepth 1 -maxdepth 1 -type d -print | head -n 1
}

finalize_timeout_trace() {
  local result_file="$1"
  local logs_dir py
  logs_dir="$(find_trial_logs_dir "$result_file" || true)"
  [[ -n "${logs_dir:-}" && -d "$logs_dir" ]] || {
    log_msg "timeout finalize skipped: missing logs dir for $result_file"
    return 0
  }

  py="${HARBOR_OPIK_PYTHON:-$HOME/.local/share/uv/tools/opik/bin/python}"
  [[ -x "$py" ]] || py="python3"

  # start.sh commonly receives the user-facing Opik base URL without /api, while
  # the hook finalizers use the Opik SDK/client path that expects the /api form
  # in this deployment. harboropik.sh normalizes this inside task containers;
  # repeat that normalization here for host-side timeout replay.
  local normalized_opik_url="${OPIK_URL_OVERRIDE:-${OPIK_URL:-}}"
  normalized_opik_url="${normalized_opik_url%/}"
  if [[ -n "$normalized_opik_url" && "$normalized_opik_url" != */api ]]; then
    normalized_opik_url="${normalized_opik_url}/api"
  fi
  if [[ -n "$normalized_opik_url" ]]; then
    export OPIK_URL_OVERRIDE="$normalized_opik_url"
    export OPIK_URL="$normalized_opik_url"
  fi

  # Harbor reports AgentTimeoutError after the task container has been torn
  # down. Finalize from the hook backups copied into the host-visible logs dir.
  if harbor_agent_is_opencode; then
    "$py" "$HARBOR_OPENCODE_DIR/finalize_opencode_sessions.py" \
      --status timeout --logs-dir "$logs_dir" >> "$WORKER_LOG" 2>&1 || true
  else
    python3 "$SCRIPT_DIR/harbor_worker_utils.py" prepare-claude-timeout-backup \
      "$logs_dir" --project-name "$OPIK_PROJECT_NAME" >> "$WORKER_LOG" 2>&1 || true
    "$py" "$TRACE_PLUGIN_CLAUDE_HOOK_SOURCE" \
      ReplayTimeout --logs-dir "$logs_dir" >> "$WORKER_LOG" 2>&1 || true
  fi
}

run_claimed_task() {
  local task_name="$1"
  local task_jobs_root="$2"
  (
    export HARBOR_ROOT MODEL AGENT API_KEY BASE_URL TRACE_TO_OPIK OPIK_URL OPIK_URL_OVERRIDE OPIK_PROJECT_NAME OPIK_API_KEY OPIK_WORKSPACE
    export TB_PATH="$DATASET_PATH"
    # Trace naming in the Claude hook uses TB_TASK_ID as the canonical
    # per-task identifier. Keep INCLUDE_TASKS for Harbor task selection.
    export TB_TASK_ID="$task_name"
    export TB_INCLUDE_TASKS="$task_name"
    export INCLUDE_TASKS="$task_name"
    export TB_LIMIT=""
    export TB_RUNS="$N_ATTEMPTS"
    export TB_N_CONCURRENT=1
    export TB_MAX_RETRIES="$MAX_RETRIES"
    export JOBS_ROOT="$task_jobs_root"

    if harbor_agent_is_opencode; then
      export OPENCODE_VERSION OPENCODE_CONFIG_CONTENT
    else
      export CC_OPIK_DEBUG
      export CLAUDE_CODE_VERSION CLAUDE_CODE_TGZ_BASENAME LOCAL_WHEEL_DIR
      export TB_LOCAL_WHEEL_SERVER_URL TB_LOCAL_CLAUDE_TGZ_URL LOCAL_WHEEL_PORT
    fi

    bash "$SCRIPT_DIR/harboropik.sh"
  )
}

while true; do
  picked="$(harbor_pick_task || true)"
  if [[ -z "${picked:-}" ]]; then
    log_msg "no more tasks, exiting"
    break
  fi

  task_index="$(printf '%s' "$picked" | cut -f1)"
  task_name="$(printf '%s' "$picked" | cut -f2-)"
  task_safe="$(safe_name "$task_name")"
  task_jobs_root="$JOBS_ROOT/worker-${WORKER_ID}/${task_index}-${task_safe}"
  task_console_log="$OUTPUT_PATH/${task_index}-${task_safe}.console.log"

  mkdir -p "$task_jobs_root"
  printf '%s\t%s\n' "$task_index" "$task_name" > "$CURRENT_FILE"
  log_msg "starting task ${task_index}: $task_name"
  # Dry-run does not create Claude JSONL logs; starting the tailer there leaves
  # a waiting Python process behind after the worker exits.  Tailer is
  # Claude-Code-specific (reads claude-code.txt stream-json events).
  if [[ "${TB_DRY_RUN:-0}" != "1" && "$AGENT" == "claude-code" ]]; then
    stream_claude_log "$task_jobs_root" &
    CLAUDE_TAIL_PID="$!"
  fi

  set +e
  run_claimed_task "$task_name" "$task_jobs_root" 2>&1 | tee "$task_console_log"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ -n "${CLAUDE_TAIL_PID:-}" ]]; then
    pkill -TERM -P "$CLAUDE_TAIL_PID" >/dev/null 2>&1 || true
    kill "$CLAUDE_TAIL_PID" >/dev/null 2>&1 || true
    wait "$CLAUDE_TAIL_PID" >/dev/null 2>&1 || true
    CLAUDE_TAIL_PID=""
  fi

  result_file="$(find_latest_trial_result "$task_jobs_root" || true)"
  if [[ "${TB_DRY_RUN:-0}" == "1" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$task_index" "$task_name" "dry-run" "" "$task_console_log" >> "$QUEUE_DIR/done.txt"
    log_msg "dry-run task ${task_index}: ${task_name} (exit=$rc)"
  elif [[ -n "${result_file:-}" ]] && summary="$(summarize_result "$result_file")"; then
    reward="$(echo "$summary" | sed -n '1p')"
    exception_type="$(echo "$summary" | sed -n '2p')"
    if [[ "${exception_type:-}" == "AgentTimeoutError" ]]; then
      finalize_timeout_trace "$result_file"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$task_index" "$task_name" "${reward:-}" "${exception_type:-}" "$result_file" >> "$QUEUE_DIR/done.txt"
    if [[ "$(harbor_metric_mode)" == "success" ]]; then
      log_msg "finished task ${task_index}: ${task_name} (success=${reward:-none} exception=${exception_type:-none} exit=$rc)"
    else
      log_msg "finished task ${task_index}: ${task_name} (reward=${reward:-none} exception=${exception_type:-none} exit=$rc)"
    fi
  else
    printf '%s\t%s\t%s\n' "$task_index" "$task_name" "$rc" >> "$QUEUE_DIR/failed.txt"
    log_msg "failed task ${task_index}: ${task_name} (exit=$rc, missing trial result)"
  fi

  rm -f "$CURRENT_FILE"
done
