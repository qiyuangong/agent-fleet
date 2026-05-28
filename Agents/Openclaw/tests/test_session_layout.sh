#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$OPENCLAW_DIR/scripts"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OUT="$TMP_DIR/layout.kdl"
TOTAL_WORKERS=3 LAYOUT_FILE="$OUT" "$SCRIPT_DIR/gen_session_zellij_layout.sh" "$OUT"

grep -q 'tab name="overview" focus=true' "$OUT"
grep -q 'command "./monitor_openclaw_sessions.sh"' "$OUT"
grep -q 'command "./stream_openclaw_session.sh"' "$OUT"

count="$(grep -c 'command "./stream_openclaw_session.sh"' "$OUT")"
test "$count" -eq 3
