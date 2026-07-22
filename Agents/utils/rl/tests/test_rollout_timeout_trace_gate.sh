#!/usr/bin/env bash
set -euo pipefail

RL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARBOR_DIR="$(cd "$RL_DIR/../common/Harbor" && pwd)"

# Exercise the real shared predicate and rollout timeout function without
# starting the persistent rollout worker loop.
source /dev/stdin <<EOF
$(sed -n '/^harbor_trace_to_opik_enabled()/,/^}/p' "$HARBOR_DIR/env.sh")
$(sed -n '/^finalize_timeout_trace()/,/^}/p' "$RL_DIR/run_rl_rollout_worker.sh")
EOF

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
probe="$tmp/find-trial-logs-dir.called"
LOGGED=""

log_msg() { LOGGED="${1:-}"; }
find_trial_logs_dir() {
  : > "$probe"
  printf '%s\n' ""
}

for TRACE_TO_OPIK in false 0; do
  for RL_AGENT in claude-code opencode; do
    rm -f "$probe"
    LOGGED=""
    finalize_timeout_trace "/tmp/rollout-trace-gate-result.json"
    [[ ! -e "$probe" ]] || {
      echo "$RL_AGENT resolved logs with TRACE_TO_OPIK=$TRACE_TO_OPIK" >&2
      exit 1
    }
    [[ "$LOGGED" == *"TRACE_TO_OPIK=false"* ]] || {
      echo "$RL_AGENT missing trace-off skip log: $LOGGED" >&2
      exit 1
    }
  done
done

# Tracing on must continue into the existing logs-dir resolution path.
TRACE_TO_OPIK=true
RL_AGENT=claude-code
rm -f "$probe"
finalize_timeout_trace "/tmp/rollout-trace-gate-result.json"
[[ -e "$probe" ]] || {
  echo "trace-on rollout did not resolve the trial logs dir" >&2
  exit 1
}

echo "rollout timeout trace gate OK"
