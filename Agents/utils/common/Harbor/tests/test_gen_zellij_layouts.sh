#!/usr/bin/env bash
set -euo pipefail

HARBOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP_DIR="$(mktemp -d)"
WRAPPER_PID=""

cleanup() {
  if [[ -n "$WRAPPER_PID" ]]; then
    kill "$WRAPPER_PID" 2>/dev/null || true
    wait "$WRAPPER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_TMP_DIR"
}
trap cleanup EXIT

run_gen() {
  local script="$1"
  local out="$2"
  local total_workers="$3"
  env -i \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$TEST_TMP_DIR/home" \
    RUN_ID="layout-test" \
    OUTPUT_PATH="$TEST_TMP_DIR/run" \
    TOTAL_WORKERS="$total_workers" \
    bash "$HARBOR_DIR/$script" "$out"
}

assert_command_panes_close_on_exit() {
  local layout="$1"
  local expected_commands="$2"
  local commands close
  commands="$(grep -c 'command "' "$layout" || true)"
  close="$(grep -c 'close_on_exit true' "$layout" || true)"
  if [[ "$commands" -ne "$expected_commands" ]]; then
    echo "expected $expected_commands command panes in $layout, found $commands" >&2
    return 1
  fi
  if [[ "$close" -ne "$commands" ]]; then
    echo "expected close_on_exit true on every command pane in $layout: commands=$commands close_on_exit=$close" >&2
    return 1
  fi
}

assert_registry_wrapper_keep_open() {
  local wrapper_dir="$TEST_TMP_DIR/registry-wrapper"
  local output="$TEST_TMP_DIR/registry-run"
  local log="$TEST_TMP_DIR/registry-wrapper.log"
  mkdir -p "$wrapper_dir"
  cp "$HARBOR_DIR/run_harbor_registry.sh" "$wrapper_dir/"
  cat > "$wrapper_dir/env.sh" <<'SH'
OUTPUT_PATH="${OUTPUT_PATH:?}"
HARBOR_ZELLIJ_CLOSE_ON_COMPLETE="${HARBOR_ZELLIJ_CLOSE_ON_COMPLETE:-1}"
export OUTPUT_PATH HARBOR_ZELLIJ_CLOSE_ON_COMPLETE
SH
  cat > "$wrapper_dir/harboropik.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$OUTPUT_PATH"
printf 'registry summary\n' > "$OUTPUT_PATH/summary.txt"
exit 7
SH
  chmod +x "$wrapper_dir/harboropik.sh" "$wrapper_dir/run_harbor_registry.sh"

  HARBOR_ZELLIJ_CLOSE_ON_COMPLETE=0 OUTPUT_PATH="$output" \
    bash "$wrapper_dir/run_harbor_registry.sh" >"$log" 2>&1 &
  WRAPPER_PID="$!"
  local deadline=$((SECONDS + 10))
  until grep -q 'keeping final registry pane open' "$log" 2>/dev/null; do
    if ! kill -0 "$WRAPPER_PID" 2>/dev/null || [[ "$SECONDS" -ge "$deadline" ]]; then
      cat "$log" >&2
      echo "registry wrapper did not stay open" >&2
      return 1
    fi
    sleep 0.1
  done
  grep -q '^registry summary$' "$log"
  kill "$WRAPPER_PID" 2>/dev/null || true
  wait "$WRAPPER_PID" 2>/dev/null || true
  WRAPPER_PID=""

  local status=0
  OUTPUT_PATH="$output" bash "$wrapper_dir/run_harbor_registry.sh" >/dev/null 2>&1 || status="$?"
  [[ "$status" -eq 7 ]]
}

main() {
  local layout

  # Local layout: 12 workers exercises the overview tab plus a workers tab.
  layout="$TEST_TMP_DIR/local-layout.kdl"
  run_gen gen_harbor_zellij_layout.sh "$layout" 12 >/dev/null
  # 12 worker panes plus the monitor pane.
  assert_command_panes_close_on_exit "$layout" 13

  # Registry layout: a single harboropik.sh pane.
  layout="$TEST_TMP_DIR/registry-layout.kdl"
  run_gen gen_harbor_registry_zellij_layout.sh "$layout" 1 >/dev/null
  assert_command_panes_close_on_exit "$layout" 1
  grep -q 'command "./run_harbor_registry.sh"' "$layout"
  assert_registry_wrapper_keep_open

  echo "ok"
}

main "$@"
