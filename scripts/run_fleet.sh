#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=fleet_spec_io.sh
source "$SCRIPT_DIR/fleet_spec_io.sh"
[[ "${1:-}" != "--prompt" && "${1:-}" != "-p" ]] || exec bash "$SCRIPT_DIR/fleet_goal.sh" "$@"
for arg in "$@"; do
  if [[ "$arg" == "--prompt" || "$arg" == "-p" ]]; then
    printf '[ERROR] %s must be the first argument\n' "$arg" >&2
    exit 2
  fi
done
usage() {
  cat <<EOF
Usage:
  $0 --taskset <taskset> [--agent <agent>] [--workers <n>] [--output <file>] [--detach] [--dry-run]
  $0 --spec <file|-> [--output <file>] [--detach] [--dry-run]
  $0 --prompt <text> [--output <file>] [--detach] [--dry-run]

Short flags: -t --taskset, -a --agent, -n --workers, -s --spec, -p --prompt,
             -o --output, -d --detach

Tasksets: seta, smith, terminalbench21, sweverify, a registry id, a local
          path (./dir), or the OpenClaw tasksets: pinchbench, clawbio
Agents:   claude-code, opencode; openclaw for OpenClaw tasksets

Examples:
  $0 -t terminalbench21 -a claude-code -n 10 -d
  $0 -p "Run terminalbench21 with claude-code and 2 workers"
EOF
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

apply_fleet_spec() {
  TASKSET="$(jq -r '.taskset' <<<"$FLEET_SPEC_JSON")"
  AGENT_ARG="$(jq -r 'if has("agent") then .agent else "" end' <<<"$FLEET_SPEC_JSON")"
  WORKERS="$(jq -r 'if has("workers") then (.workers | tostring) else "" end' <<<"$FLEET_SPEC_JSON")"
}

TASKSET="" AGENT_ARG="" WORKERS="" SPEC_SOURCE="" OUTPUT="" FLEET_SPEC_JSON=""
DETACH=0 DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--taskset) TASKSET="$2"; shift 2 ;;
    -a|--agent) AGENT_ARG="$2"; shift 2 ;;
    -n|--workers) WORKERS="$2"; shift 2 ;;
    -s|--spec)
      [[ $# -ge 2 ]] || { printf '[ERROR] --spec requires a file path or -\n' >&2; exit 2; }
      SPEC_SOURCE="$2"; shift 2
      ;;
    -o|--output)
      [[ $# -ge 2 && -n "$2" ]] || { printf '[ERROR] --output requires a non-empty file path\n' >&2; exit 2; }
      if fleet_spec_is_option_shaped "$2"; then
        printf '[ERROR] --output requires a file path; use ./%s for a file literally named %s\n' "$2" "$2" >&2
        exit 2
      fi
      OUTPUT="$2"; shift 2
      ;;
    -d|--detach) DETACH=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

fleet_spec_validate_output_path "$OUTPUT" || exit $?

if [[ -n "$SPEC_SOURCE" ]]; then
  if [[ -n "$TASKSET" || -n "$AGENT_ARG" || -n "$WORKERS" ]]; then
    printf '[ERROR] --spec cannot be combined with --taskset, --agent, or --workers\n' >&2
    exit 2
  fi
  fleet_spec_load "$SPEC_SOURCE"
  apply_fleet_spec
fi

[[ -n "$TASKSET" ]] || { usage >&2; exit 2; }
if [[ -n "$OUTPUT" ]]; then
  if [[ -z "$FLEET_SPEC_JSON" ]]; then
    fleet_spec_from_taskset_args "$TASKSET" "$AGENT_ARG" "$WORKERS"
    apply_fleet_spec
  fi
  fleet_spec_write "$OUTPUT" "$FLEET_SPEC_JSON"
fi

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
