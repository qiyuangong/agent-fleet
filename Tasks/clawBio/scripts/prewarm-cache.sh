#!/usr/bin/env bash
# Clone/update ClawBio plugin to a local cache directory.
#
# This script:
# 1. Clones the ClawBio marketplace repository (shallow)
# 2. Fixes .git permissions for container access
#
# Usage:
#   ./prewarm-cache.sh
#   CACHE_DIR=/path/to/cache ./prewarm-cache.sh
#   ./prewarm-cache.sh --cache-dir /path/to/cache
#
# Environment variables:
#   CACHE_DIR          Cache directory (default: Tasks/clawBio/cache)
#   MARKETPLACE_URL    Plugin repo URL (default: https://github.com/ClawBio/ClawBio.git)
#   PLUGIN_CACHE_OWNER Owner applied after sync so OpenClaw accepts the plugin (default: root:root)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CACHE_DIR="${CACHE_DIR:-$BENCH_DIR/cache}"
MARKETPLACE_URL="${MARKETPLACE_URL:-https://github.com/ClawBio/ClawBio.git}"
PLUGIN_NAME="${PLUGIN_NAME:-clawbio}"
PLUGIN_CACHE_OWNER="${PLUGIN_CACHE_OWNER:-root:root}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Clone/update ClawBio plugin to a local cache directory.

Options:
  --cache-dir DIR        Cache directory (default: Tasks/clawBio/cache)
  --marketplace-url URL  Plugin repo URL (default: https://github.com/ClawBio/ClawBio.git)
  -h, --help             Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cache-dir)
      [ "$#" -ge 2 ] || { echo "Error: --cache-dir requires a value." >&2; exit 1; }
      CACHE_DIR="$2"
      shift 2
      ;;
    --marketplace-url)
      [ "$#" -ge 2 ] || { echo "Error: --marketplace-url requires a value." >&2; exit 1; }
      MARKETPLACE_URL="$2"
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

# ── Check dependencies ──
if ! command -v git &>/dev/null; then
  echo "Error: git is required." >&2
  exit 1
fi

plugin_dir="$CACHE_DIR/$PLUGIN_NAME"

echo "ClawBio Cache Prewarm"
echo "  CACHE_DIR:        $CACHE_DIR"
echo "  MARKETPLACE_URL:  $MARKETPLACE_URL"
echo ""

mkdir -p "$CACHE_DIR"

chown_cache() {
  local owner="$1"
  local target="$2"
  if [ "$owner" = "skip" ] || [ ! -e "$target" ]; then
    return 0
  fi
  if chown -R "$owner" "$target" 2>/dev/null; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1 && sudo -n chown -R "$owner" "$target" 2>/dev/null; then
    return 0
  fi
  echo "Error: cannot chown $target to $owner." >&2
  echo "Set PLUGIN_CACHE_OWNER=skip to bypass ownership normalization." >&2
  exit 1
}

# ── Clone or update ──
if [ -d "$plugin_dir/.git" ]; then
  echo "Updating existing clone at $plugin_dir ..."
  if [ ! -w "$plugin_dir/.git" ]; then
    chown_cache "$(id -u):$(id -g)" "$plugin_dir"
  fi
  (cd "$plugin_dir" && git fetch --all && git reset --hard "$(git rev-parse '@{u}' 2>/dev/null || echo HEAD)")
else
  echo "Cloning to $plugin_dir ..."
  rm -rf "$plugin_dir"
  git clone --depth 1 "$MARKETPLACE_URL" "$plugin_dir"
fi

# Make git internals writable for plugin installer copy operations
chmod -R u+w "$plugin_dir/.git" 2>/dev/null || true
chmod -R a+rX "$plugin_dir" 2>/dev/null || true
chown_cache "$PLUGIN_CACHE_OWNER" "$plugin_dir"

echo ""
echo "Cache ready: $plugin_dir"
echo "Cache owner: $PLUGIN_CACHE_OWNER"
echo ""
echo "Next: PLUGIN_CACHE_DIR=$(cd "$CACHE_DIR" && pwd) ./Agents/Openclaw/scripts/setup.sh <COUNT>"
