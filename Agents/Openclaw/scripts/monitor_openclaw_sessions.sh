#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${OPENCLAW_PROJECT_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
ENV_FILE="$PROJECT_DIR/.env"

cfg="$PROJECT_DIR/config/fleet.env"
if [[ -f "$cfg" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$cfg"
  set +a
fi

BASE_GW_PORT=18789
PORT_STEP="${PORT_STEP:-20}"
DEFAULT_PORTS_OFFSET="${DEFAULT_PORTS_OFFSET:-0}"
POLL_INTERVAL="${OPENCLAW_SESSION_POLL_INTERVAL:-2}"
CONFIG_BASE="${CONFIG_BASE:-$HOME/openclaw-instances}"
CONTAINER_NAME_PREFIX="${CONTAINER_NAME_PREFIX:-openclaw}"
ALT_SCREEN="${OPENCLAW_SESSION_ALT_SCREEN:-true}"

instance_count() {
  if [[ -f "$ENV_FILE" ]]; then
    grep -c '^TOKEN_' "$ENV_FILE" 2>/dev/null || printf '0\n'
  else
    printf '0\n'
  fi
}

render_error() {
  printf '\033[2J\033[H'
  cat <<EOF
OpenClaw Session Monitor

$1
EOF
}

use_alt_screen() {
  [[ "$ALT_SCREEN" == "true" && -t 1 ]]
}

enter_alt_screen() {
  if use_alt_screen; then
    printf '\033[?1049h\033[?25l'
  fi
}

leave_alt_screen() {
  if use_alt_screen; then
    printf '\033[?25h\033[?1049l'
  fi
}

trap leave_alt_screen EXIT INT TERM
enter_alt_screen

while true; do
  total_workers="$(instance_count)"
  if [[ "$total_workers" -le 0 ]]; then
    render_error "No OpenClaw instances found. Run ./Agents/Openclaw/scripts/setup.sh first."
    sleep "$POLL_INTERVAL"
    continue
  fi

  if ! output="$(python3 "$SCRIPT_DIR/monitor_openclaw_sessions.py" \
    --total-workers "$total_workers" \
    --base-port "$BASE_GW_PORT" \
    --port-step "$PORT_STEP" \
    --port-offset "$DEFAULT_PORTS_OFFSET" \
    --config-base "$CONFIG_BASE" \
    --container-prefix "$CONTAINER_NAME_PREFIX" \
    --columns "${COLUMNS:-80}" \
    --lines "${LINES:-24}" \
    --pretty 2>&1)"; then
    render_error "$output"
    sleep "$POLL_INTERVAL"
    continue
  fi

  printf '\033[2J\033[H'
  printf '%s\n' "$output"
  sleep "$POLL_INTERVAL"
done
