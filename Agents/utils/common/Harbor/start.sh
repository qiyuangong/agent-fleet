#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN_ID="${RUN_ID:-$(date +%Y-%m-%d-%H%M)-harbor-tui}"
. "$SCRIPT_DIR/env.sh"

DETACH_MODE=false
if [[ "${1:-}" == "--detach" ]]; then
  DETACH_MODE=true
  shift
fi

# Explicit names still win for normal benchmark zellij sessions.
ZELLIJ_SESSION_NAME="${ZELLIJ_SESSION_NAME:-${RL_ZELLIJ_SESSION_NAME:-$OPIK_PROJECT_NAME}}"

harbor_stop_rollout_zellij_sessions() {
  local session
  while IFS= read -r session; do
    case "$session" in
      harbor-rollout-*)
        zellij kill-session "$session" >/dev/null 2>&1 || true
        zellij delete-session "$session" >/dev/null 2>&1 || true
        ;;
    esac
  done < <(zellij list-sessions --short 2>/dev/null || true)
}

ensure_zellij_web_sharing_config() {
  local config_file="${ZELLIJ_CONFIG_FILE:-$HOME/.config/zellij/config.kdl}"
  mkdir -p "$(dirname "$config_file")"
  if [[ -f "$config_file" ]] && grep -qE '^[[:space:]]*web_sharing[[:space:]]+' "$config_file"; then
    sed -i -E 's/^[[:space:]]*web_sharing[[:space:]]+".*"$/web_sharing "on"/' "$config_file"
  else
    printf '\nweb_sharing "on"\n' >> "$config_file"
  fi
}

harbor_start_online_analysis_if_enabled() {
  if [[ "$HARBOR_ONLINE_ANALYSIS" != "1" ]]; then
    return 0
  fi
  if [[ -f "$HARBOR_ONLINE_ANALYSIS_PID_FILE" ]]; then
    local existing_pid
    existing_pid="$(cat "$HARBOR_ONLINE_ANALYSIS_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" >/dev/null 2>&1; then
      return 0
    fi
  fi

  mkdir -p "$HARBOR_ONLINE_ANALYSIS_DIR" "$RUNTIME_DIR"
  local online_analysis_profile
  online_analysis_profile="$(harbor_dataset_kind)"
  nohup setsid python3 "$SCRIPT_DIR/scripts/online_rule_analyzer.py" \
    "$OUTPUT_PATH" \
    --follow \
    --profile "$online_analysis_profile" \
    --poll-interval "$HARBOR_ONLINE_ANALYSIS_POLL_INTERVAL" \
    --output-dir "$HARBOR_ONLINE_ANALYSIS_DIR" \
    >>"$HARBOR_ONLINE_ANALYSIS_LOG_FILE" 2>&1 &
  printf '%s\n' "$!" >"$HARBOR_ONLINE_ANALYSIS_PID_FILE"
}

harbor_init_run_dirs
if [[ "$ROLLOUT" != "1" ]]; then
  harbor_validate_agent
  harbor_ensure_dataset
else
  mkdir -p "$RL_TRIALS_DIR" "$RL_ACTIVE_DIR" "$RL_QUEUE_DIR/pending" "$RL_QUEUE_DIR/results" "$RL_JOB_QUEUE_ROOT" "$RL_JOB_RUNTIME_ROOT" "$(dirname "$RL_TRACE_LOG")"
  touch "$RL_TRACE_LOG"
fi
if [[ "${RESET_RUN:-0}" == "1" ]]; then
  if [[ "$ROLLOUT" == "1" ]]; then
    "$RL_UTILS_DIR/run_rl_rollout_server.sh" --stop >/dev/null 2>&1 || true
    harbor_stop_rollout_zellij_sessions
  else
    zellij kill-session "$ZELLIJ_SESSION_NAME" >/dev/null 2>&1 || true
    zellij delete-session "$ZELLIJ_SESSION_NAME" >/dev/null 2>&1 || true
  fi
  harbor_reset_run_state
  if [[ "$ROLLOUT" == "1" ]]; then
    rm -rf "$RL_JOB_QUEUE_ROOT" "$RL_JOB_RUNTIME_ROOT" 2>/dev/null || true
    mkdir -p "$RL_JOB_QUEUE_ROOT" "$RL_JOB_RUNTIME_ROOT"
    rm -f "$RL_ACTIVE_DIR"/*.json "$RL_QUEUE_DIR"/pending/*.json "$RL_QUEUE_DIR"/results/*.json "$RL_TRACE_LOG" "$RL_SERVER_LOG" 2>/dev/null || true
    touch "$RL_TRACE_LOG"
  fi
fi

if [[ $# -gt 0 ]]; then
  if [[ "$ROLLOUT" != "1" ]] && ! harbor_uses_registry_dataset; then
    harbor_prepare_task_file
  fi
  if [[ "$ROLLOUT" != "1" ]]; then
    harbor_start_online_analysis_if_enabled
  fi
  exec "$@"
fi

if [[ "$ROLLOUT" != "1" ]] && ! harbor_uses_registry_dataset; then
  harbor_prepare_task_file
fi
if [[ "$ROLLOUT" != "1" ]]; then
  harbor_start_online_analysis_if_enabled
fi
cd "$SCRIPT_DIR"

if [[ "$ROLLOUT" == "1" ]]; then
  if [[ "$DETACH_MODE" == "true" ]]; then
    exec "$RL_UTILS_DIR/run_rl_rollout_server.sh" --detach
  fi
  exec "$RL_UTILS_DIR/run_rl_rollout_server.sh"
fi

if harbor_uses_registry_dataset; then
  "$SCRIPT_DIR/gen_harbor_registry_zellij_layout.sh" "$LAYOUT_FILE"
else
  "$SCRIPT_DIR/gen_harbor_zellij_layout.sh" "$LAYOUT_FILE"
fi
ensure_zellij_web_sharing_config

if [[ "$DETACH_MODE" == "true" ]]; then
  zellij kill-session "$ZELLIJ_SESSION_NAME" >/dev/null 2>&1 || true
  zellij delete-session "$ZELLIJ_SESSION_NAME" >/dev/null 2>&1 || true
  zellij_cmd="$(printf 'stty rows 54 cols 172; exec zellij --session %q --new-session-with-layout %q' "$ZELLIJ_SESSION_NAME" "$LAYOUT_FILE")"
  nohup setsid env -u ZELLIJ_SESSION_NAME TERM=xterm-256color script -q \
    -c "$zellij_cmd" \
    "$RUNTIME_DIR/zellij-${ZELLIJ_SESSION_NAME}.typescript" \
    >"$RUNTIME_DIR/zellij-${ZELLIJ_SESSION_NAME}.log" 2>&1 &

  started=false
  for _ in $(seq 1 30); do
    if zellij list-sessions --short 2>/dev/null | grep -qx "$ZELLIJ_SESSION_NAME"; then
      started=true
      break
    fi
    sleep 1
  done

  if [[ "$started" != "true" ]]; then
    echo "failed to create zellij session: $ZELLIJ_SESSION_NAME" >&2
    exit 1
  fi

  printf '%s\n' "$ZELLIJ_SESSION_NAME"
  exit 0
fi

exec env -u ZELLIJ_SESSION_NAME zellij --session "$ZELLIJ_SESSION_NAME" --new-session-with-layout "$LAYOUT_FILE"
