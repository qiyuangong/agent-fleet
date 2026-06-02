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
CONTAINER_NAME_PREFIX="${CONTAINER_NAME_PREFIX:-openclaw}"
POLL_INTERVAL="${OPENCLAW_SESSION_POLL_INTERVAL:-2}"
CONFIG_BASE="${CONFIG_BASE:-$HOME/openclaw-instances}"
ALT_SCREEN="${OPENCLAW_SESSION_ALT_SCREEN:-true}"

instance="${1:?instance number required}"
container_name="${CONTAINER_NAME_PREFIX}-${instance}"
port=$((BASE_GW_PORT + DEFAULT_PORTS_OFFSET + (instance - 1) * PORT_STEP))
store_root="$CONFIG_BASE/$instance"

render_error() {
  printf '\033[2J\033[H'
  cat <<EOF
Instance: ${container_name}
Port:     ${port}
State:    error

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
  if [[ ! -f "$ENV_FILE" ]]; then
    render_error "Missing $ENV_FILE. Run ./Agents/Openclaw/scripts/setup.sh first."
    sleep "$POLL_INTERVAL"
    continue
  fi

  if [[ ! -d "$store_root" ]] && ! docker inspect "$container_name" >/dev/null 2>&1; then
    render_error "Missing session store root and container is unavailable: $store_root / $container_name"
    sleep "$POLL_INTERVAL"
    continue
  fi

  if ! output="$(python3 "$SCRIPT_DIR/stream_openclaw_session.py" \
    --instance "$instance" \
    --port "$port" \
    --store-root "$store_root" \
    --container-name "$container_name" \
    --pretty 2>&1)"; then
    render_error "$output"
    sleep "$POLL_INTERVAL"
    continue
  fi

  printf '\033[2J\033[H'
  printf '%s\n' "$output"
  sleep "$POLL_INTERVAL"
done
