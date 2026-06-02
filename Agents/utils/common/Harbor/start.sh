#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RUN_ID="${RUN_ID:-$(date +%Y-%m-%d-%H%M)-harbor-tui}"
. "$SCRIPT_DIR/env.sh"
harbor_validate_agent
harbor_ensure_opik_plugin_workspace

DETACH_MODE=false
if [[ "${1:-}" == "--detach" ]]; then
  DETACH_MODE=true
  shift
fi

# Default both interactive and detached zellij session names to the Opik project.
ZELLIJ_SESSION_NAME="${ZELLIJ_SESSION_NAME:-$OPIK_PROJECT_NAME}"

ensure_zellij_web_sharing_config() {
  local config_file="${ZELLIJ_CONFIG_FILE:-$HOME/.config/zellij/config.kdl}"
  mkdir -p "$(dirname "$config_file")"
  if [[ -f "$config_file" ]] && grep -qE '^[[:space:]]*web_sharing[[:space:]]+' "$config_file"; then
    sed -i -E 's/^[[:space:]]*web_sharing[[:space:]]+".*"$/web_sharing "on"/' "$config_file"
  else
    printf '\nweb_sharing "on"\n' >> "$config_file"
  fi
}

harbor_init_run_dirs
harbor_ensure_dataset
if [[ "${RESET_RUN:-0}" == "1" ]]; then
  zellij kill-session "$ZELLIJ_SESSION_NAME" >/dev/null 2>&1 || true
  zellij delete-session "$ZELLIJ_SESSION_NAME" >/dev/null 2>&1 || true
  harbor_reset_run_state
fi
harbor_prepare_task_file

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

cd "$SCRIPT_DIR"
"$SCRIPT_DIR/gen_harbor_zellij_layout.sh" "$LAYOUT_FILE"
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
