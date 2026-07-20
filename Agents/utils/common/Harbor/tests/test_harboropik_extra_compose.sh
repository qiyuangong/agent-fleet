#!/usr/bin/env bash
set -euo pipefail

HARBOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_DIR=""

make_fake_bin() {
  local fake_bin="$1"
  mkdir -p "$fake_bin"

  cat >"$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "info" ]]; then
  exit 0
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 1
fi
exit 0
SH

  cat >"$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ "$arg" == "%{http_code}" ]]; then
    printf '200'
  fi
done
exit 0
SH

  cat >"$fake_bin/git" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  cat >"$fake_bin/uv" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  cat >"$fake_bin/uvx" <<'SH'
#!/usr/bin/env bash
exit 0
SH

  chmod +x "$fake_bin"/docker "$fake_bin"/curl "$fake_bin"/git "$fake_bin"/uv "$fake_bin"/uvx
}

make_capture_bin() {
  local path="$1"
  cat >"$path" <<'SH'
#!/usr/bin/env bash
python3 - "$HARBOR_CAPTURE_FILE" "$@" <<'PY'
import sys
from pathlib import Path

capture = Path(sys.argv[1])
args = sys.argv[2:]
capture.parent.mkdir(parents=True, exist_ok=True)
capture.write_bytes(b"\0".join(arg.encode() for arg in args) + b"\0")
PY
SH
  chmod +x "$path"
}

assert_extra_compose_arg() {
  local capture_file="$1"
  local overlay_file="$2"
  python3 - "$capture_file" "$overlay_file" <<'PY'
import sys
from pathlib import Path

capture = Path(sys.argv[1])
overlay = sys.argv[2]
args = [part.decode() for part in capture.read_bytes().split(b"\0") if part]
try:
    index = args.index("--extra-docker-compose")
except ValueError:
    raise SystemExit(f"missing --extra-docker-compose in command: {args!r}")
if index == len(args) - 1:
    raise SystemExit(f"--extra-docker-compose is missing its path value: {args!r}")
if args[index + 1] != overlay:
    raise SystemExit(
        f"unexpected extra compose path {args[index + 1]!r}; expected {overlay!r}"
    )
PY
}

assert_structured_mount_arg() {
  local capture_file="$1"
  local source_dir="$2"
  local target_dir="$3"
  python3 - "$capture_file" "$source_dir" "$target_dir" <<'PY'
import json
import sys
from pathlib import Path

capture = Path(sys.argv[1])
source = sys.argv[2]
target = sys.argv[3]
args = [part.decode() for part in capture.read_bytes().split(b"\0") if part]
try:
    index = args.index("--mounts-json")
except ValueError:
    raise SystemExit(f"missing --mounts-json in command: {args!r}")
if index == len(args) - 1:
    raise SystemExit(f"--mounts-json is missing its JSON value: {args!r}")
mounts = json.loads(args[index + 1])
if not all(isinstance(mount, dict) for mount in mounts):
    raise SystemExit(f"mounts must be structured objects: {mounts!r}")
expected = {
    "type": "bind",
    "source": source,
    "target": target,
    "read_only": True,
}
if expected not in mounts:
    raise SystemExit(f"missing expected mount {expected!r}: {mounts!r}")
PY
}

assert_arg_pair() {
  local capture_file="$1"
  local option="$2"
  local expected="$3"
  python3 - "$capture_file" "$option" "$expected" <<'PY'
import sys
from pathlib import Path

args = [part.decode() for part in Path(sys.argv[1]).read_bytes().split(b"\0") if part]
option, expected = sys.argv[2:]
if not any(args[index:index + 2] == [option, expected] for index in range(len(args) - 1)):
    raise SystemExit(f"missing {option} {expected!r} in command: {args!r}")
PY
}

run_harboropik() {
  local agent="$1"
  local capture_bin="$2"
  local capture_file="$3"
  local output_dir="$4"
  local dataset_name="${5:-example/dataset@1.0}"
  local include_tasks="${6:-}"
  local fake_bin
  local trace_dir
  local wheel_dir
  fake_bin="$(dirname "$capture_bin")"
  mkdir -p "$output_dir"
  mkdir -p "$output_dir/run/runtime/$agent"
  wheel_dir="$output_dir/wheels"
  mkdir -p "$wheel_dir"
  trace_dir="$output_dir/trace"
  mkdir -p \
    "$trace_dir/src/sii_opik_plugin/claude_code" \
    "$trace_dir/src/sii_opik_plugin/opencode" \
    "$trace_dir/harness/opencode"
  : >"$trace_dir/src/sii_opik_plugin/claude_code/claude_realtime_trace.py"
  : >"$trace_dir/src/sii_opik_plugin/opencode/opencode_realtime_trace.py"
  : >"$trace_dir/harness/opencode/opik-trace.ts"

  local log_file="$output_dir/$agent.log"
  if ! env -i \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$output_dir/home" \
    AGENT="$agent" \
    DATASET_NAME="$dataset_name" \
    INCLUDE_TASKS="$include_tasks" \
    OUTPUT_PATH="$output_dir/run" \
    HARBOR_QUEUE_WORKER="1" \
    OPIK_MODE="remote" \
    OPIK_BASE="http://opik.example" \
    OPIK_URL_OVERRIDE="http://opik.example/api" \
    OPIK_API_KEY="fake-opik-key" \
    BASE_URL="http://llm.example" \
    API_KEY="fake-llm-key" \
    MODEL="fake-model" \
    TRACE_TO_OPIK="true" \
    TB_TRACE_TO_OPIK="true" \
    TB_CC_OPIK_ENABLE_HOOK="1" \
    TB_CC_PY_WHEEL_DIR_SOURCE="$wheel_dir" \
    TRACE_PLUGIN_SOURCE_DIR="$trace_dir" \
    TB_SKIP_DOCKERHUB_PREFLIGHT="1" \
    TB_RUNS="1" \
    N_ATTEMPTS="1" \
    TB_N_CONCURRENT="1" \
    TOTAL_WORKERS="1" \
    TB_MAX_RETRIES="0" \
    HARBOR_CAPTURE_FILE="$capture_file" \
    HARBOR_OPIK_BIN="$capture_bin" \
    HARBOR_OPIK_PYTHON="$capture_bin" \
    OPENCODE_CONFIG_CONTENT="{}" \
    bash "$HARBOR_DIR/harboropik.sh" >"$log_file" 2>&1; then
    cat "$log_file" >&2
    return 1
  fi
}

main() {
  local tmp fake_bin default_overlay claude_capture opencode_capture capture_bin
  local seta_capture sweverify_capture
  tmp="$(mktemp -d)"
  TEST_TMP_DIR="$tmp"
  trap 'rm -rf "$TEST_TMP_DIR"' EXIT

  fake_bin="$tmp/bin"
  make_fake_bin "$fake_bin"
  capture_bin="$fake_bin/capture"
  make_capture_bin "$capture_bin"

  default_overlay="$HARBOR_DIR/overlays/unprivileged-task.yaml"

  claude_capture="$tmp/claude-default.args"
  run_harboropik \
    "claude-code" "$capture_bin" "$claude_capture" "$tmp/claude-default" \
    "codepde@1.0"
  assert_extra_compose_arg "$claude_capture" "$default_overlay"
  assert_arg_pair "$claude_capture" "--dataset" "codepde@1.0"

  opencode_capture="$tmp/opencode-default.args"
  run_harboropik \
    "opencode" "$capture_bin" "$opencode_capture" "$tmp/opencode-default" \
    "terminalbench21" "fix-git"
  assert_extra_compose_arg "$opencode_capture" "$default_overlay"
  assert_arg_pair "$opencode_capture" "--dataset" "terminal-bench/terminal-bench-2-1"
  assert_arg_pair "$opencode_capture" "-i" "terminal-bench/fix-git"
  assert_structured_mount_arg \
    "$opencode_capture" \
    "$tmp/opencode-default/wheels" \
    "/opt/tb-opik/python-wheels"

  seta_capture="$tmp/seta-default.args"
  run_harboropik \
    "opencode" "$capture_bin" "$seta_capture" "$tmp/seta-default" \
    "seta" "0"
  assert_arg_pair "$seta_capture" "--dataset" "seta-env"
  assert_arg_pair "$seta_capture" "-i" "0"

  sweverify_capture="$tmp/sweverify-default.args"
  run_harboropik \
    "opencode" "$capture_bin" "$sweverify_capture" "$tmp/sweverify-default" \
    "sweverify" "astropy__astropy-12907"
  assert_arg_pair "$sweverify_capture" "--dataset" "swebench-verified"
  assert_arg_pair "$sweverify_capture" "-i" "astropy__astropy-12907"
}

main "$@"
