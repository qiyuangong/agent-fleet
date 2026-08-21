#!/usr/bin/env bash
set -euo pipefail

# Shared repository configuration loader. This is a sourced library, not an
# entry point. It resolves source precedence only; compatibility fallbacks are
# opt-in so tool-specific aliases remain scoped to the tool that owns them.

agent_fleet_load_config() {
  local repo_root="$1"
  local entry file name
  local -a caller_env=()

  if [[ "${AGENT_FLEET_CONFIG_LOADED_ROOT:-}" == "$repo_root" ]]; then
    return 0
  fi

  # Save the runtime/exported environment before loading saved configuration.
  # compgen is a Bash builtin and works on the older Bash shipped by macOS;
  # avoid depending on the GNU-specific `env -0` option.
  while IFS= read -r name; do
    caller_env+=("$name=${!name-}")
  done < <(compgen -e)

  # Base template first, private saved configuration second.
  for file in "$repo_root/config.env" "$repo_root/config.local.env"; do
    if [[ -f "$file" ]]; then
      set -a
      # shellcheck source=/dev/null
      . "$file"
      set +a
    fi
  done

  # Runtime/exported values are the highest-priority layer.
  for entry in "${caller_env[@]}"; do
    name="${entry%%=*}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    export "$entry"
  done

  AGENT_FLEET_CONFIG_LOADED_ROOT="$repo_root"
  export AGENT_FLEET_CONFIG_LOADED_ROOT

  agent_fleet_resolve_trace_to_opik
}

# Opik is optional, so an absent switch must not demand an Opik server. Derive
# it from OPIK_URL instead: a configured endpoint means tracing was wanted, no
# endpoint means it was not. Callers that load their own config files (the
# OpenClaw image build, the ClawBio launcher) source this library for the helper
# and call it once their own precedence chain has been applied.
#
# Only the derivation is announced; an explicit switch stays silent. Tools whose
# output is parsed rather than read (the Harbor controller emits JSON) set
# AGENT_FLEET_CONFIG_QUIET=1 so a repeated diagnostic cannot reach their callers.
agent_fleet_resolve_trace_to_opik() {
  if [[ -n "${TRACE_TO_OPIK:-}" ]]; then
    export TRACE_TO_OPIK
    return 0
  fi

  local reason
  if [[ -n "${OPIK_URL:-}" ]]; then
    TRACE_TO_OPIK=true
    reason="OPIK_URL present -> tracing on"
  else
    TRACE_TO_OPIK=false
    reason="no OPIK_URL -> tracing off"
  fi
  if [[ "${AGENT_FLEET_CONFIG_QUIET:-0}" != "1" ]]; then
    echo "[INFO] TRACE_TO_OPIK unset; $reason" >&2
  fi
  export TRACE_TO_OPIK
}

# AUTH_TOKEN is a documented fleet-runner credential alias, not a general
# replacement for API_KEY. Apply it only after canonical configuration has
# loaded so a saved or runtime API_KEY keeps precedence.
agent_fleet_apply_auth_token_fallback() {
  if [[ -z "${API_KEY:-}" && -n "${AUTH_TOKEN:-}" ]]; then
    API_KEY="$AUTH_TOKEN"
    export API_KEY
  fi
}
