#!/usr/bin/env bash
# Sourced library for FleetSpec v1 I/O; not an entry point. It must not set
# global shell options or EXIT traps: both are process-wide and belong to the
# sourcing script. It resolves its own jq module directory, so callers owe it
# nothing beyond bash and (for load/write) jq.

FLEET_SPEC_IO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fleet_spec_is_option_shaped() {
  # Any dash-prefixed value is a mangled command line, not a filename: an
  # allowlist of known options would silently accept mistyped ones (--dryrn)
  # and turn an intended preview into a live run. A file literally named
  # like an option stays expressible as ./-name. Bare - falls through so the
  # output-path validation rejects it with its stdin-specific message.
  case "$1" in
    -) return 1 ;;
    -*) return 0 ;;
    *) return 1 ;;
  esac
}

fleet_spec_validate_output_path() {
  local output="$1" output_dir
  [[ -n "$output" ]] || return 0
  [[ "$output" != "-" ]] || {
    printf '[ERROR] --output requires a file path, not -\n' >&2
    return 2
  }
  output_dir="$(dirname -- "$output")"
  [[ -d "$output_dir" ]] || {
    printf '[ERROR] output directory does not exist: %s\n' "$output_dir" >&2
    return 2
  }
  [[ ! -d "$output" ]] || {
    printf '[ERROR] output path is a directory: %s\n' "$output" >&2
    return 2
  }
}

fleet_spec_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf '[ERROR] jq is required for FleetSpec JSON\n' >&2
    return 1
  }
}

fleet_spec_load() {
  local source="$1" spec_json
  fleet_spec_require_jq || return
  if [[ "$source" == "-" ]]; then
    spec_json="$(cat)"
  elif [[ -f "$source" && -r "$source" ]]; then
    spec_json="$(cat -- "$source")"
  else
    printf '[ERROR] FleetSpec is not readable: %s\n' "$source" >&2
    return 2
  fi

  if ! FLEET_SPEC_JSON="$(jq -ces -L "$FLEET_SPEC_IO_DIR" '
    include "fleet_spec_validate";
    if length == 1 then (.[0] | fleet_spec_v1)
    else error("invalid FleetSpec") end
  ' <<<"$spec_json" 2>/dev/null)"; then
    printf '[ERROR] invalid FleetSpec v1: %s\n' "$source" >&2
    printf '[ERROR] expected schema_version=1, taskset, optional agent/workers, and no other fields\n' >&2
    return 2
  fi
}

fleet_spec_from_taskset_args() {
  local taskset="$1" agent="$2" workers="$3"
  fleet_spec_require_jq || return
  if ! FLEET_SPEC_JSON="$(jq -cen -L "$FLEET_SPEC_IO_DIR" \
    --arg taskset "$taskset" --arg agent "$agent" --arg workers "$workers" '
    include "fleet_spec_validate";
    ({schema_version: 1, taskset: $taskset}
      + (if $agent == "" then {} else {agent: $agent} end)
      + (if $workers == "" then {} else {workers: ($workers | tonumber)} end))
    | fleet_spec_v1
  ' 2>/dev/null)"; then
    printf '[ERROR] taskset arguments do not form a valid FleetSpec v1\n' >&2
    return 2
  fi
}

fleet_spec_write() {
  local output="$1" spec_json="$2" output_dir tmp_file
  [[ -n "$output" ]] || return 0
  fleet_spec_validate_output_path "$output" || return
  output_dir="$(dirname -- "$output")"
  tmp_file="$(mktemp "$output_dir/.fleet-spec.XXXXXX")"
  # Clean up explicitly rather than via an EXIT trap: the EXIT slot is
  # process-global, so a library trap would clobber any trap the caller set.
  if ! jq . <<<"$spec_json" >"$tmp_file" || ! mv -f -- "$tmp_file" "$output"; then
    rm -f -- "$tmp_file"
    printf '[ERROR] failed to write FleetSpec: %s\n' "$output" >&2
    return 1
  fi
  printf '[INFO] FleetSpec written: %s\n' "$output" >&2
}
