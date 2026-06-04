#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/openclaw"
mkdir -p "$PROJECT_DIR/scripts" \
         "$PROJECT_DIR/cache/openclaw/.git" \
         "$TMP_DIR/third_party/sii-opik-plugin/harness/openclaw" \
         "$TMP_DIR/third_party/sii-opik-plugin/src/sii_opik_plugin/openclaw" \
         "$TMP_DIR/bin"
touch "$TMP_DIR/third_party/sii-opik-plugin/src/sii_opik_plugin/openclaw/openclaw_opik_tracer.py"
touch "$TMP_DIR/third_party/sii-opik-plugin/requirements.txt"
printf '{"scripts":{"build":"true"}}\n' > "$TMP_DIR/third_party/sii-opik-plugin/harness/openclaw/package.json"

cp "$OPENCLAW_DIR/scripts/build-openclaw-image.sh" "$PROJECT_DIR/scripts/build-openclaw-image.sh"
cp "$OPENCLAW_DIR/Dockerfile.opik" "$PROJECT_DIR/Dockerfile.opik"
chmod +x "$PROJECT_DIR/scripts/build-openclaw-image.sh"

LOG="$TMP_DIR/commands.log"

cat > "$TMP_DIR/bin/git" <<'MOCK'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$LOG"
exit 0
MOCK

cat > "$TMP_DIR/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$LOG"
exit 0
MOCK

cat > "$TMP_DIR/bin/npm" <<'MOCK'
#!/usr/bin/env bash
printf 'npm %s NPM_CONFIG_REGISTRY=%s\n' "$*" "${NPM_CONFIG_REGISTRY:-}" >> "$LOG"
if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then
  mkdir -p dist
  : > dist/index.js
fi
exit 0
MOCK

chmod +x "$TMP_DIR/bin/git" "$TMP_DIR/bin/docker" "$TMP_DIR/bin/npm"

PATH="$TMP_DIR/bin:$PATH" \
LOG="$LOG" \
OPIK_PLUGIN=enabled \
TRACE_PLUGIN_SOURCE_DIR="$TMP_DIR/third_party/sii-opik-plugin" \
NPM_CONFIG_REGISTRY="https://registry.npmmirror.com" \
PIP_INDEX_URL="https://pypi.tuna.tsinghua.edu.cn/simple" \
PIP_EXTRA_INDEX_URL="https://pypi.example.com/simple" \
PIP_TRUSTED_HOST="pypi.tuna.tsinghua.edu.cn" \
"$PROJECT_DIR/scripts/build-openclaw-image.sh" >/dev/null

grep -q 'registry=https://registry.npmmirror.com' "$PROJECT_DIR/cache/openclaw/.npmrc"
grep -q -- '--build-arg PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple' "$LOG"
grep -q -- '--build-arg PIP_EXTRA_INDEX_URL=https://pypi.example.com/simple' "$LOG"
grep -q -- '--build-arg PIP_TRUSTED_HOST=pypi.tuna.tsinghua.edu.cn' "$LOG"
grep -q -- '--build-arg NPM_CONFIG_REGISTRY=https://registry.npmmirror.com' "$LOG"
