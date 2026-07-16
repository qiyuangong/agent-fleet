#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat <<EOF
Usage:
  $0 --taskset <taskset> [--agent <agent>] [--workers <n>] [--detach] [--dry-run]
  $0 --spec <file|-> [--detach] [--dry-run]

OpenClaw tasksets: pinchbench, clawbio
EOF
}

load_spec() {
  local source="$1" spec_json

  command -v jq >/dev/null 2>&1 || {
    printf '[ERROR] jq is required to read FleetSpec JSON\n' >&2
    return 1
  }
  if [[ "$source" == "-" ]]; then
    spec_json="$(cat)"
  elif [[ -f "$source" && -r "$source" ]]; then
    spec_json="$(cat -- "$source")"
  else
    printf '[ERROR] FleetSpec is not readable: %s\n' "$source" >&2
    return 2
  fi

  if ! spec_json="$(jq -ces '
    if length == 1 and (.[0] |
      type == "object" and
      ((keys - ["agent", "schema_version", "taskset", "workers"]) | length == 0) and
      (.schema_version == 1) and
      (.taskset | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
      ((has("agent") | not) or
        (.agent | type == "string" and length > 0 and (test("[[:cntrl:]]") | not))) and
      ((has("workers") | not) or
        (.workers | type == "number" and . > 0 and . == floor and . <= 4096))
    ) then .[0] else error("invalid FleetSpec") end
  ' <<<"$spec_json" 2>/dev/null)"; then
    printf '[ERROR] invalid FleetSpec v1: %s\n' "$source" >&2
    printf '[ERROR] expected schema_version=1, taskset, optional agent/workers, and no other fields\n' >&2
    return 2
  fi

  TASKSET="$(jq -r '.taskset' <<<"$spec_json")"
  AGENT_ARG="$(jq -r 'if has("agent") then .agent else "" end' <<<"$spec_json")"
  # floor normalizes integral floats (3.0 -> "3"); otherwise the spec value
  # flows downstream as TOTAL_WORKERS=3.0, which breaks bash arithmetic and
  # pinchbench's integer --instances parsing.
  WORKERS="$(jq -r 'if has("workers") then (.workers | floor | tostring) else "" end' <<<"$spec_json")"
}

run_command() {
  if (( DRY_RUN )); then
    printf 'Command:'
    printf ' %q' "$@"
    printf '\n'
    exit 0
  fi
  exec "$@"
}

TASKSET="" AGENT_ARG="" WORKERS="" SPEC_SOURCE="" DETACH=0 DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--taskset) TASKSET="$2"; shift 2 ;;
    -a|--agent) AGENT_ARG="$2"; shift 2 ;;
    -n|--workers) WORKERS="$2"; shift 2 ;;
    --spec)
      [[ $# -ge 2 ]] || { printf '[ERROR] --spec requires a file path or -\n' >&2; exit 2; }
      SPEC_SOURCE="$2"; shift 2
      ;;
    --detach) DETACH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

if [[ -n "$SPEC_SOURCE" ]]; then
  if [[ -n "$TASKSET" || -n "$AGENT_ARG" || -n "$WORKERS" ]]; then
    printf '[ERROR] --spec cannot be combined with --taskset, --agent, or --workers\n' >&2
    exit 2
  fi
  load_spec "$SPEC_SOURCE"
fi

[[ -n "$TASKSET" ]] || { usage >&2; exit 2; }

REQUESTED_AGENT="${AGENT_ARG:-${AGENT:-}}"
if [[ "$TASKSET" == "pinchbench" || "$TASKSET" == "clawbio" ]] &&
   [[ -n "$REQUESTED_AGENT" && "$REQUESTED_AGENT" != "openclaw" ]]; then
  printf '[WARN] requested agent: %s; taskset: %s; actual agent: openclaw (requested agent ignored)\n' "$REQUESTED_AGENT" "$TASKSET" >&2
fi
if (( DETACH )) && [[ "$TASKSET" == "pinchbench" || "$TASKSET" == "clawbio" ]]; then
  printf '[WARN] --detach ignored for taskset: %s; runner remains in foreground\n' "$TASKSET" >&2
fi

case "$TASKSET" in
  pinchbench)
    cmd=(python3 "$REPO_DIR/Tasks/Pinchbench/scripts/run-parallel-workers.py")
    [[ -z "$WORKERS" ]] || cmd+=(--instances "$WORKERS")
    run_command "${cmd[@]}"
    ;;
  clawbio)
    cmd=(bash "$REPO_DIR/Tasks/clawBio/scripts/run-openclaw-clawbio.sh")
    [[ -z "$WORKERS" ]] || cmd=(env "COUNT=$WORKERS" "${cmd[@]}")
    run_command "${cmd[@]}"
    ;;
esac

harbor_env=()
case "$TASKSET" in
  /*|./*|../*|.|..|\~/*)
    taskset_path="${TASKSET/#\~/$HOME}"
    [[ "$taskset_path" == /* ]] || taskset_path="$PWD/$taskset_path"
    harbor_env+=("DATASET_NAME=auto" "DATASET_PATH=$taskset_path" "TB_PATH=$taskset_path")
    ;;
  *) harbor_env+=("DATASET_NAME=$TASKSET") ;;
esac

[[ -z "$AGENT_ARG" ]] || harbor_env+=("AGENT=$AGENT_ARG" "TB_AGENT=$AGENT_ARG")
[[ -z "$WORKERS" ]] || harbor_env+=("TOTAL_WORKERS=$WORKERS" "TB_N_CONCURRENT=$WORKERS")

# Assemble the full command in one always-non-empty array: expanding an
# empty array under `set -u` is an unbound-variable error on bash < 4.4
# (macOS /bin/bash 3.2), which broke every run without --detach.
harbor_cmd=(env "${harbor_env[@]}" bash "$REPO_DIR/Agents/utils/common/Harbor/start.sh")
(( DETACH )) && harbor_cmd+=(--detach)
run_command "${harbor_cmd[@]}"
