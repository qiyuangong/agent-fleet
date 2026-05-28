#!/usr/bin/env bash
# Thin wrapper around scripts/setup.py.
#
# Loads config/fleet.env so the Python entry point inherits the same env-var
# precedence as the historical Bash implementation (later overrides earlier):
#   1. Environment variables already set by the caller
#   2. config/fleet.env (sourced after caller env, so matching keys win)
#   3. CLI flags / positional COUNT (handled inside setup.py)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cfg="$PROJECT_DIR/config/fleet.env"
if [ -f "$cfg" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$cfg"
  set +a
fi

PY="${PYTHON:-python3}"
exec "$PY" "$SCRIPT_DIR/setup.py" "$@"
