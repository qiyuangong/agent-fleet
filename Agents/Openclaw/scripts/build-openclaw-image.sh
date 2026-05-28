#!/usr/bin/env bash
# Build the openclaw Docker image.
#
# Default:       builds openclaw:local from the openclaw repo.
# OPIK_PLUGIN=enabled: builds openclaw:local-opik with the opik-tracer plugin.
#
# Variables:
#   OPENCLAW_REPO   OpenClaw git repo URL  (default: https://github.com/openclaw/openclaw.git)
#   OPIK_PLUGIN_WORKSPACE  sii-opik-plugin checkout (default: /workspace/sii-opik-plugin)
#   TRACE_PLUGIN_SOURCE_DIR  optional override for the plugin checkout
#   NPM_CONFIG_REGISTRY  npm/pnpm registry mirror for builds
#   PIP_INDEX_URL        pip index mirror for the Opik image layer
#   PIP_EXTRA_INDEX_URL  optional extra pip index for the Opik image layer
#   PIP_TRUSTED_HOST     optional pip trusted host for the Opik image layer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"

OPENCLAW_REPO="${OPENCLAW_REPO:-https://github.com/openclaw/openclaw.git}"

OPENCLAW_CACHE="$PROJECT_DIR/cache/openclaw"
OPIK_PLUGIN_WORKSPACE="${OPIK_PLUGIN_WORKSPACE:-/workspace/sii-opik-plugin}"
OPIK_PLUGIN_GIT_URL="${OPIK_PLUGIN_GIT_URL:-https://github.com/sii-system/sii-opik-plugin.git}"
OPIK_PLUGIN_GIT_REF="${OPIK_PLUGIN_GIT_REF:-sii-dev}"
TRACE_PLUGIN_SOURCE_DIR="${TRACE_PLUGIN_SOURCE_DIR:-$OPIK_PLUGIN_WORKSPACE}"
PLUGIN_SRC="$TRACE_PLUGIN_SOURCE_DIR/harness/openclaw"

OPIK_DOCKER_BUILD_ARGS=()

if [ -n "${NPM_CONFIG_REGISTRY:-}" ]; then
  export NPM_CONFIG_REGISTRY
fi

add_opik_build_arg() {
  local name="$1"
  local value="${!name:-}"
  if [ -n "$value" ]; then
    OPIK_DOCKER_BUILD_ARGS+=(--build-arg "$name=$value")
  fi
}

add_opik_build_arg PIP_INDEX_URL
add_opik_build_arg PIP_EXTRA_INDEX_URL
add_opik_build_arg PIP_TRUSTED_HOST
add_opik_build_arg NPM_CONFIG_REGISTRY

opik_plugin_workspace_complete() {
  [ -d "$PLUGIN_SRC" ] &&
    [ -f "$TRACE_PLUGIN_SOURCE_DIR/harness/openclaw/package.json" ] &&
    [ -f "$TRACE_PLUGIN_SOURCE_DIR/src/sii_opik_plugin/openclaw/openclaw_opik_tracer.py" ] &&
    [ -f "$TRACE_PLUGIN_SOURCE_DIR/requirements.txt" ]
}

ensure_opik_plugin_workspace() {
  if opik_plugin_workspace_complete; then
    return 0
  fi

  if [ -e "$TRACE_PLUGIN_SOURCE_DIR" ]; then
    echo "Error: sii-opik-plugin workspace is incomplete: $TRACE_PLUGIN_SOURCE_DIR" >&2
    echo "Set OPIK_PLUGIN_WORKSPACE or TRACE_PLUGIN_SOURCE_DIR to a complete checkout." >&2
    exit 1
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "Error: missing command: git" >&2
    exit 1
  fi

  echo "Cloning sii-opik-plugin into: $TRACE_PLUGIN_SOURCE_DIR"
  mkdir -p "$(dirname "$TRACE_PLUGIN_SOURCE_DIR")"
  git clone "$OPIK_PLUGIN_GIT_URL" "$TRACE_PLUGIN_SOURCE_DIR"
  if [ -n "$OPIK_PLUGIN_GIT_REF" ]; then
    git -C "$TRACE_PLUGIN_SOURCE_DIR" checkout "$OPIK_PLUGIN_GIT_REF"
  fi

  if ! opik_plugin_workspace_complete; then
    echo "Error: sii-opik-plugin checkout is incomplete after clone: $TRACE_PLUGIN_SOURCE_DIR" >&2
    exit 1
  fi
}

update_npmrc_mirror() {
  local repo_dir="$1"
  local npmrc="$repo_dir/.npmrc"
  local tmp="${npmrc}.tmp.$$"
  local had_npmrc=0

  if [ -f "$npmrc" ]; then
    had_npmrc=1
    awk '
      /^# agent-fleet mirror start$/ { skip = 1; next }
      /^# agent-fleet mirror end$/ { skip = 0; next }
      skip != 1 { print }
    ' "$npmrc" > "$tmp"
  else
    : > "$tmp"
  fi

  if [ -n "${NPM_CONFIG_REGISTRY:-}" ]; then
    {
      cat "$tmp"
      printf '\n# agent-fleet mirror start\n'
      printf 'registry=%s\n' "$NPM_CONFIG_REGISTRY"
      printf '# agent-fleet mirror end\n'
    } > "${tmp}.with-mirror"
    mv "${tmp}.with-mirror" "$tmp"
  fi

  if [ -s "$tmp" ] || [ -n "${NPM_CONFIG_REGISTRY:-}" ]; then
    mv "$tmp" "$npmrc"
  elif [ "$had_npmrc" -eq 1 ]; then
    mv "$tmp" "$npmrc"
  else
    rm -f "$tmp"
  fi
}

# ── Step 1: Clone or update the openclaw repo ──
OPENCLAW_PINNED_REF="v2026.5.10-beta.1"

if [ -d "$OPENCLAW_CACHE/.git" ]; then
  echo "Updating existing openclaw cache..."
  git -C "$OPENCLAW_CACHE" fetch --all || true
else
  echo "Cloning openclaw repo..."
  rm -rf "$OPENCLAW_CACHE"
  git clone "$OPENCLAW_REPO" "$OPENCLAW_CACHE"
fi

echo "Checking out pinned openclaw ref: $OPENCLAW_PINNED_REF"
git -C "$OPENCLAW_CACHE" checkout "$OPENCLAW_PINNED_REF"

update_npmrc_mirror "$OPENCLAW_CACHE"

# ── Step 2: Build openclaw:local ──
echo "Building openclaw:local..."
docker buildx build --load -t openclaw:local "$OPENCLAW_CACHE"

echo ""
echo "Done. Image: openclaw:local"

# ── Opik layer (only when OPIK_PLUGIN=enabled) ──
if [ "${OPIK_PLUGIN:-}" != "enabled" ]; then
  exit 0
fi

echo ""
echo "OPIK_PLUGIN=enabled — building opik layer..."

# ── Step 3: Ensure the sii-opik-plugin workspace ──
ensure_opik_plugin_workspace

# ── Step 4: Build openclaw:local-opik ──
echo "Building openclaw:local-opik..."
OPIK_BUILD_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-opik-context.XXXXXX")"
trap 'rm -rf "$OPIK_BUILD_CONTEXT"' EXIT
cp -R "$TRACE_PLUGIN_SOURCE_DIR" "$OPIK_BUILD_CONTEXT/sii-opik-plugin"
docker buildx build --load \
  "${OPIK_DOCKER_BUILD_ARGS[@]}" \
  -t openclaw:local-opik \
  -f "$PROJECT_DIR/Dockerfile.opik" \
  "$OPIK_BUILD_CONTEXT"

echo ""
echo "Done. Image: openclaw:local-opik"
echo "To use: OPIK_PLUGIN=enabled OPIK_URL=... OPIK_PROJECT_NAME=... ./Agents/Openclaw/scripts/setup.sh"
