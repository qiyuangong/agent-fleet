#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$OPENCLAW_DIR/scripts/stream_openclaw_session.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/openclaw/config"
cat > "$TMP_DIR/openclaw/.env" <<'EOF'
TOKEN_1=dummy
EOF

SESSION_DIR="$TMP_DIR/openclaw-instances/1/agents/main/sessions"
mkdir -p "$SESSION_DIR"
cat > "$SESSION_DIR/sessions.json" <<'EOF'
{
  "agent:main:main": {
    "sessionId": "sess-1",
    "updatedAt": 1776833100000,
    "status": "active",
    "lastTo": "+123",
    "sessionFile": "/home/node/.openclaw/agents/main/sessions/sess-1.jsonl"
  }
}
EOF
cat > "$SESSION_DIR/sess-1.jsonl" <<'EOF'
{"type":"message","timestamp":"2026-04-22T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}
{"type":"message","timestamp":"2026-04-22T10:00:05Z","message":{"role":"assistant","content":[{"type":"text","text":"world"}]}}
{"type":"message","timestamp":"2026-04-22T10:00:10Z","message":{"role":"user","content":[{"type":"text","text":"stderr should not break JSON"}]}}
EOF

OUTPUT="$TMP_DIR/output.txt"
python3 - <<PY
import os
import subprocess
from pathlib import Path

env = os.environ.copy()
env["OPENCLAW_PROJECT_DIR"] = "${TMP_DIR}/openclaw"
env["CONFIG_BASE"] = "${TMP_DIR}/openclaw-instances"
env["OPENCLAW_SESSION_POLL_INTERVAL"] = "1"
env["TERM"] = "xterm"
out_path = Path("${OUTPUT}")
with out_path.open("w", encoding="utf-8") as out:
    try:
        subprocess.run(["${SCRIPT}", "1"], env=env, stdout=out, stderr=subprocess.STDOUT, timeout=3, check=False)
    except subprocess.TimeoutExpired:
        pass
PY

grep -q 'state=active turns=2' "$OUTPUT"
grep -q 'stderr should not break JSON' "$OUTPUT"
! grep -q 'Invalid session JSON' "$OUTPUT"
