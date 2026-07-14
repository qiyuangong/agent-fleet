#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

usage() {
  cat <<EOF
Usage: $0 --taskset <taskset> [--agent <agent>] [--workers <n>] [--dry-run]

OpenClaw tasksets: pinchbench, clawbio
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

TASKSET="" AGENT_ARG="" WORKERS="" DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--taskset) TASKSET="$2"; shift 2 ;;
    -a|--agent) AGENT_ARG="$2"; shift 2 ;;
    -n|--workers) WORKERS="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

[[ -n "$TASKSET" ]] || { usage >&2; exit 2; }

REQUESTED_AGENT="${AGENT_ARG:-${AGENT:-}}"
if [[ "$TASKSET" == "pinchbench" || "$TASKSET" == "clawbio" ]] &&
   [[ -n "$REQUESTED_AGENT" && "$REQUESTED_AGENT" != "openclaw" ]]; then
  printf '[WARN] requested agent: %s; taskset: %s; actual agent: openclaw (requested agent ignored)\n' "$REQUESTED_AGENT" "$TASKSET" >&2
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

run_command env "${harbor_env[@]}" bash "$REPO_DIR/Agents/utils/common/Harbor/start.sh"
