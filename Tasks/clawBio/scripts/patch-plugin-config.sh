#!/usr/bin/env bash
# Patch generated openclaw.json files to add clawbio plugin loading.
#
# Run this AFTER Agents/Openclaw/scripts/setup.sh and BEFORE docker compose up.
# It modifies each instance's openclaw.json to:
#   - Add /opt/plugin-cache/clawbio to plugins.load.paths
#   - Add "clawbio" to plugins.allow
#   - Add "clawbio" entry to plugins.entries
#
# Usage:
#   ./patch-plugin-config.sh
#   CONFIG_BASE=~/openclaw-instances ./patch-plugin-config.sh
#
# Environment variables:
#   CONFIG_BASE        Per-instance config root (default: $HOME/openclaw-instances)
#   PLUGIN_NAME        Plugin directory name under /opt/plugin-cache (default: clawbio)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OPENCLAW_DIR="$PROJECT_DIR/Agents/Openclaw"

CONFIG_BASE="${CONFIG_BASE:-$HOME/openclaw-instances}"
PLUGIN_NAME="${PLUGIN_NAME:-clawbio}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Patch generated openclaw.json files to add clawbio plugin loading.

Options:
  --config-base DIR    Per-instance config root (default: \$HOME/openclaw-instances)
  --plugin-name NAME   Plugin name (default: clawbio)
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --config-base)
      [ "$#" -ge 2 ] || { echo "Error: --config-base requires a value." >&2; exit 1; }
      CONFIG_BASE="$2"
      shift 2
      ;;
    --plugin-name)
      [ "$#" -ge 2 ] || { echo "Error: --plugin-name requires a value." >&2; exit 1; }
      PLUGIN_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "Error: unexpected argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# ── Validate ──
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required for patching openclaw.json." >&2
  exit 1
fi

ENV_FILE="$OPENCLAW_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: $ENV_FILE not found. Run Agents/Openclaw/scripts/setup.sh first." >&2
  exit 1
fi

# ── Discover instances from TOKEN_N entries ──
count=0
for line in $(grep -E '^TOKEN_[0-9]+=' "$ENV_FILE"); do
  idx="${line#TOKEN_}"
  idx="${idx%=*}"
  count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  echo "Error: No TOKEN_N entries found in $ENV_FILE." >&2
  exit 1
fi

echo "Patching $count instance(s) in $CONFIG_BASE ..."

chmod_mount() {
  local target="$1"
  if chmod -R a+rwX "$target" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n chmod -R a+rwX "$target" 2>/dev/null; then
    return 0
  fi
  echo "Error: cannot chmod benchmark config mount: $target" >&2
  echo "Re-run with sudo or fix mount permissions before patching." >&2
  exit 1
}

chmod_mount "$CONFIG_BASE"

# ── Patch each instance ──
for i in $(seq 1 "$count"); do
  CONFIG_JSON="$CONFIG_BASE/$i/openclaw.json"

  if [ ! -f "$CONFIG_JSON" ]; then
    echo "Error: config not found: $CONFIG_JSON" >&2
    exit 1
  fi

  jq_expr=".plugins.load.paths = (.plugins.load.paths // []) + [\"/opt/plugin-cache/${PLUGIN_NAME}\"]"
  jq_expr+=" | .plugins.allow += [\"${PLUGIN_NAME}\"]"
  jq_expr+=" | .plugins.entries[\"${PLUGIN_NAME}\"] = {\"enabled\": true}"
  jq_expr+=" | .tools.deny += [\"group:web\"]"

  if ! jq "$jq_expr" "$CONFIG_JSON" > "${CONFIG_JSON}.tmp"; then
    rm -f "${CONFIG_JSON}.tmp"
    echo "Error: failed to patch $CONFIG_JSON" >&2
    exit 1
  fi
  mv "${CONFIG_JSON}.tmp" "$CONFIG_JSON"
  chmod a+rw "$CONFIG_JSON" 2>/dev/null || true

  echo "  instance $i: patched ($CONFIG_JSON)"
done

echo ""
echo "Patch complete. Run 'docker compose up -d' to start the fleet."
