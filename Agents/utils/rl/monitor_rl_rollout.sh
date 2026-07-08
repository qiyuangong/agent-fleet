#!/usr/bin/env bash
set -euo pipefail

RL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_SCRIPT_DIR="${HARBOR_SCRIPT_DIR:-$(cd "$RL_SCRIPT_DIR/../common/Harbor" && pwd)}"
. "$HARBOR_SCRIPT_DIR/env.sh"

mkdir -p "$RUNTIME_DIR" "$RL_ACTIVE_DIR" "$RL_QUEUE_DIR/pending" "$RL_QUEUE_DIR/results"

count_files() {
  local dir="$1"
  find "$dir" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' '
}

dataset_task_count() {
  local worklist
  worklist="$(find "$RL_QUEUE_DIR/worklists" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$worklist" && -s "$worklist" ]]; then
    awk 'NF {n++} END {print n+0}' "$worklist"
  elif [[ -d "$RL_DATASET_ROOT" ]]; then
    find "$RL_DATASET_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
  else
    echo 0
  fi
}

result_stats() {
  python3 - "$RL_QUEUE_DIR/results" <<'PY'
import json
import sys
from collections import Counter
from pathlib import Path

results_dir = Path(sys.argv[1])
finished = gen_trace_success = task_success = 0
exceptions: Counter[str] = Counter()
rewards: Counter[str] = Counter()


def is_task_success(reward: object) -> bool:
    value = str(reward or "").strip().lower()
    return value in {"1", "1.0", "true", "success", "resolved", "pass", "passed"}


if results_dir.exists():
    for path in sorted(results_dir.glob("*.json")):
        try:
            item = json.loads(path.read_text(errors="ignore"))
        except json.JSONDecodeError:
            continue
        finished += 1
        status = str(item.get("status") or "").lower()
        ok = bool(item.get("ok"))
        if ok:
            gen_trace_success += 1
        reward = item.get("reward")
        if is_task_success(reward):
            task_success += 1
        rewards["none" if reward is None else str(reward)] += 1
        exception = item.get("exception_info") or {}
        if isinstance(exception, dict):
            name = exception.get("exception_type") or ""
        else:
            name = str(exception or "")
        if name:
            exceptions[name] += 1

gen_trace_fail = finished - gen_trace_success
task_success_rate = (task_success / finished * 100.0) if finished else 0.0
print(f"finished:     {finished}")
print(f"gen_trace_success: {gen_trace_success}")
print(f"gen_trace_fail:    {gen_trace_fail}")
print()
print("reward stats:")
print(f"task_success_rate: {task_success_rate:.2f}%")
if rewards:
    for reward, count in sorted(rewards.items(), key=lambda item: (item[0] != "1.0", item[0])):
        print(f"reward={reward}: {count}")
else:
    print("(none)")
print()
print("exception stats:")
if exceptions:
    for name, count in exceptions.most_common(10):
        print(f"{name}: {count}")
else:
    print("(none)")
PY
}

active_workers() {
  local found_any=0
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    found_any=1
    worker_id="$(basename "$f" .current | sed 's/^worker-//')"
    current="$(cat "$f" 2>/dev/null || true)"
    request_id="$(printf '%s' "$current" | cut -f1)"
    task_name="$(printf '%s' "$current" | cut -f2)"
    display_name="$(printf '%s' "$current" | cut -f3)"
    polar_task_id="$(printf '%s' "$current" | cut -f5)"
    if [[ -z "$display_name" ]]; then
      display_name="$task_name"
    fi
    polar_short=""
    if [[ -n "$polar_task_id" ]]; then
      polar_short="${polar_task_id: -6}"
    fi
    printf 'worker-%s  task=%s' "$worker_id" "$display_name"
    if [[ -n "$polar_short" ]]; then
      printf '  polar=%s' "$polar_short"
    fi
    if [[ -n "$request_id" ]]; then
      printf '  request=%s' "${request_id:0:12}"
    fi
    printf '\n'
  done < <(find "$RL_ACTIVE_DIR" -maxdepth 1 -name 'worker-*.current' | sort -V)

  if [[ $found_any -eq 0 ]]; then
    echo "(none)"
  fi
}

recent_results() {
  python3 - "$RL_QUEUE_DIR/results" <<'PY'
import json
import sys
from pathlib import Path

results_dir = Path(sys.argv[1])
items = []
if results_dir.exists():
    for path in sorted(results_dir.glob("*.json"), key=lambda p: p.stat().st_mtime)[-8:]:
        try:
            item = json.loads(path.read_text(errors="ignore"))
        except json.JSONDecodeError:
            continue
        display = item.get("display_name") or item.get("task_id") or path.stem
        status = item.get("status") or ("completed" if item.get("ok") else "failed")
        reward = item.get("reward")
        exception = item.get("exception_info") or {}
        if isinstance(exception, dict):
            exc = exception.get("exception_type") or "none"
        else:
            exc = str(exception or "none")
        items.append((display, status, reward, exc))

if not items:
    print("(none)")
else:
    for display, status, reward, exc in items:
        reward_text = "none" if reward is None else reward
        print(f"- {display} status={status} reward={reward_text} exception={exc}")
PY
}

while true; do
  # Detached zellij panes may not have TERM set; do not let clear kill monitor.
  clear 2>/dev/null || printf '\033[H\033[2J'

  pending_n="$(count_files "$RL_QUEUE_DIR/pending")"
  active_n="$(count_files "$RL_ACTIVE_DIR")"
  result_n="$(count_files "$RL_QUEUE_DIR/results")"
  dataset_total="$(dataset_task_count)"

  total_requests=$((pending_n + active_n + result_n))

  echo "RL rollout Harbor"
  echo "RUN_ID:      $RUN_ID"
  echo "AGENT:       $RL_AGENT"
  echo "MODEL:       $RL_MODEL_NAME"
  echo "DATASET:     $RL_DATASET_NAME -> $RL_DATASET_ROOT"
  echo "RAY_JOB:     ${RL_ZELLIJ_JOB_ID:-all}"
  echo "POLAR_PORT:  $RL_PORT"
  echo "WORKERS:     $RL_WORKERS"
  echo "OPIK_URL:    $OPIK_URL_OVERRIDE"
  echo "OPIK_PROJECT_NAME: $OPIK_PROJECT_NAME"
  echo
  # Rollout receives tasks from Polar dynamically, so the fixed dataset size is
  # only context; the request counters below are the live job progress.
  echo "dataset_tasks:  $dataset_total"
  echo "job_requests:   $total_requests"
  echo "queued:         $pending_n"
  echo "running:        $active_n"
  echo "finished:       $result_n"
  echo
  result_stats
  echo
  echo "active workers:"
  active_workers
  echo
  echo "recent results:"
  recent_results

  sleep 2
done
