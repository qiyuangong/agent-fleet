#!/usr/bin/env bash
# Thin wrapper around scripts/setup.py.
#
# Loads config.env, config.local.env, then config/fleet.env, then re-applies
# the caller's environment so one-off overrides win. Precedence (highest first):
#   1. CLI flags / positional COUNT (handled inside setup.py)
#   2. Environment variables set by the caller (one-off overrides)
#   3. config/fleet.env (OpenClaw-specific overrides)
#   4. config.local.env (private overrides/secrets; git-ignored)
#   5. config.env (shared site configuration)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"

# Snapshot caller-provided env so one-off overrides survive the sourcing below.
__caller_env="$(export -p)"

# Shared site configuration (committed template; see config.env), sourced
# before the OpenClaw-specific fleet.env so fleet.env can still override it.
root_cfg="$REPO_ROOT/config.env"
if [ -f "$root_cfg" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$root_cfg"
  set +a
fi

# Private overrides/secrets (git-ignored), sourced after config.env so they win.
local_cfg="$REPO_ROOT/config.local.env"
if [ -f "$local_cfg" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$local_cfg"
  set +a
fi

cfg="$PROJECT_DIR/config/fleet.env"
if [ -f "$cfg" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$cfg"
  set +a
fi

# Caller-provided env wins over all the config files above.
eval "$__caller_env"
unset __caller_env

PY="${PYTHON:-python3}"
exec "$PY" "$SCRIPT_DIR/setup.py" "$@"
