#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$OPENCLAW_DIR/scripts/start-session-tui.sh"
TMP_DIR="$(mktemp -d)"
ENV_BACKUP="$TMP_DIR/original.env"
trap 'if [[ -f "$ENV_BACKUP" ]]; then mv "$ENV_BACKUP" "$OPENCLAW_DIR/.env"; else rm -f "$OPENCLAW_DIR/.env"; fi; rm -rf "$TMP_DIR"' EXIT

if [[ -f "$OPENCLAW_DIR/.env" ]]; then
  cp "$OPENCLAW_DIR/.env" "$ENV_BACKUP"
fi

printf 'TOKEN_1=a\nTOKEN_2=b\nTOKEN_3=c\n' > "$OPENCLAW_DIR/.env"
RUNTIME_DIR="$TMP_DIR/runtime"
mkdir -p "$RUNTIME_DIR"

ZELLIJ_BIN=true OPENCLAW_TUI_RUNTIME_DIR="$RUNTIME_DIR" "$SCRIPT" env >/dev/null

test -f "$RUNTIME_DIR/session-tui-layout.kdl"
grep -q 'command "./monitor_openclaw_sessions.sh"' "$RUNTIME_DIR/session-tui-layout.kdl"
grep -q 'command "./stream_openclaw_session.sh"' "$RUNTIME_DIR/session-tui-layout.kdl"

ZELLIJ_CONFIG_FILE="$TMP_DIR/zellij/config.kdl" \
  ZELLIJ_BIN=true \
  OPENCLAW_TUI_RUNTIME_DIR="$RUNTIME_DIR" \
  "$SCRIPT" >/dev/null
grep -qx 'web_sharing "on"' "$TMP_DIR/zellij/config.kdl"

printf 'web_sharing "off"\n' > "$TMP_DIR/zellij/config.kdl"
ZELLIJ_CONFIG_FILE="$TMP_DIR/zellij/config.kdl" \
  ZELLIJ_BIN=true \
  OPENCLAW_TUI_RUNTIME_DIR="$RUNTIME_DIR" \
  "$SCRIPT" >/dev/null
grep -qx 'web_sharing "on"' "$TMP_DIR/zellij/config.kdl"
