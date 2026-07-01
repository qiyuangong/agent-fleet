#!/usr/bin/env bash
# ============================================================
# setup.sh - SII Agent Fleet one-shot environment setup
#
# Idempotent: safe to re-run on failure; existing values are
# merged, not overwritten.
# ============================================================

set -euo pipefail

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Hardcoded versions (override via env if needed) ----
NODE_VERSION="${NODE_VERSION:-24}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-2.1.90}"
REPO_URL="${REPO_URL:-https://github.com/sii-system/sii-agent-fleet.git}"
REPO_DIR="${REPO_DIR:-$HOME/sii-agent-fleet}"

# ---- 1. Gather config (env vars first, then interactive prompt) ----
# Credentials: BASE_URL / MODEL come from env vars, or are prompted
# interactively if missing. AUTH_TOKEN accepts the repo-standard API_KEY
# variable as an alias (config.env uses API_KEY, not AUTH_TOKEN).
info "Gathering model endpoint config..."
[[ -z "${BASE_URL:-}" ]]   && read -rp "BASE_URL (model gateway, WITHOUT /v1): " BASE_URL
# Accept API_KEY as the repo-standard alias for AUTH_TOKEN
AUTH_TOKEN="${AUTH_TOKEN:-${API_KEY:-}}"
if [[ -z "${AUTH_TOKEN:-}" ]]; then
  read -rsp "AUTH_TOKEN (or API_KEY, input hidden): " AUTH_TOKEN
  echo
fi
[[ -z "${MODEL:-}" ]]      && read -rp "MODEL (model id, e.g. glm-5.1-fp8): " MODEL

for v in BASE_URL AUTH_TOKEN MODEL; do
  if [[ -z "${!v:-}" ]]; then
    err "Config '$v' is empty, aborting."
    exit 1
  fi
done
ok "Config gathered (BASE_URL=${BASE_URL}, MODEL=${MODEL})"

# Validate optional local Claude package config (for benchmark containers).
# Use the repo-standard TB_CC_* names; accept the short aliases too.
CLAUDE_TGZ_SOURCE="${CLAUDE_TGZ_SOURCE:-${TB_CC_CLAUDE_TGZ_SOURCE:-}}"
CLAUDE_WHEEL_DIR_SOURCE="${CLAUDE_WHEEL_DIR_SOURCE:-${TB_CC_PY_WHEEL_DIR_SOURCE:-}}"
if [[ -n "${CLAUDE_TGZ_SOURCE:-}" || -n "${CLAUDE_WHEEL_DIR_SOURCE:-}" ]]; then
  if [[ -z "${CLAUDE_TGZ_SOURCE:-}" || -z "${CLAUDE_WHEEL_DIR_SOURCE:-}" ]]; then
    warn "Only one of CLAUDE_TGZ_SOURCE / CLAUDE_WHEEL_DIR_SOURCE is set; both are needed. Ignoring local package."
    CLAUDE_TGZ_SOURCE=""; CLAUDE_WHEEL_DIR_SOURCE=""
  elif [[ ! -f "${CLAUDE_TGZ_SOURCE}" ]]; then
    warn "CLAUDE_TGZ_SOURCE not found: ${CLAUDE_TGZ_SOURCE} -- containers will fall back to public installer. Ignoring."
    CLAUDE_TGZ_SOURCE=""; CLAUDE_WHEEL_DIR_SOURCE=""
  elif [[ ! -d "${CLAUDE_WHEEL_DIR_SOURCE}/npm-cache" ]]; then
    warn "CLAUDE_WHEEL_DIR_SOURCE has no npm-cache/ subdir: ${CLAUDE_WHEEL_DIR_SOURCE} -- ignoring local package."
    CLAUDE_TGZ_SOURCE=""; CLAUDE_WHEEL_DIR_SOURCE=""
  else
    ok "Local Claude package configured for containers: ${CLAUDE_TGZ_SOURCE}"
  fi
fi

# ---- 2. Base dependency check ----
info "Checking base dependencies..."
MISSING=()
for cmd in git curl docker python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    MISSING+=("$cmd")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  err "Missing dependencies: ${MISSING[*]}"
  err "Please install them first. e.g. Ubuntu: sudo apt install ${MISSING[*]}"
  exit 1
fi
ok "Base dependencies present (git / curl / docker / python3)"

# ---- 3. Ensure Node >=18 (via nvm if needed) ----
node_major() { node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || echo 0; }
load_nvm() {
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
}

load_nvm
NEED_NODE=1
if command -v node >/dev/null 2>&1; then
  CUR_MAJOR="$(node_major)"
  if [[ "$CUR_MAJOR" -ge 18 ]]; then
    ok "Node $(node -v) OK (>=18)"
    NEED_NODE=0
  else
    warn "Node $(node -v) too old, will install Node $NODE_VERSION via nvm"
  fi
else
  warn "Node not found, will install Node $NODE_VERSION via nvm"
fi

if [[ "$NEED_NODE" == "1" ]]; then
  if ! command -v nvm >/dev/null 2>&1; then
    info "Installing nvm..."
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    load_nvm
  fi
  if ! command -v nvm >/dev/null 2>&1; then
    err "nvm install/load failed. Please install Node >=18 manually and re-run."
    exit 1
  fi
  info "Installing Node $NODE_VERSION via nvm..."
  nvm install "$NODE_VERSION"
  nvm use "$NODE_VERSION"
  nvm alias default "$NODE_VERSION" || true
  CUR_MAJOR="$(node_major)"
  if [[ "$CUR_MAJOR" -ge 18 ]]; then
    ok "Node $(node -v) ready"
  else
    err "Node still <18 after install, aborting."
    exit 1
  fi
fi

if ! command -v npm >/dev/null 2>&1; then
  err "npm not found even after Node setup, aborting."
  exit 1
fi

# ---- 4. Install Claude Code ----
info "Checking Claude Code version..."
export CLAUDE_CODE_DISABLE_AUTOUPDATER=1
NEED_INSTALL=1
if command -v claude >/dev/null 2>&1; then
  CUR_VER="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
  if [[ "$CUR_VER" == "$CLAUDE_CODE_VERSION" ]]; then
    ok "Claude Code already at target version $CLAUDE_CODE_VERSION"
    NEED_INSTALL=0
  else
    warn "Current version ${CUR_VER:-unknown}, switching to $CLAUDE_CODE_VERSION"
  fi
else
  warn "Claude Code not found, installing $CLAUDE_CODE_VERSION"
fi
if [[ "$NEED_INSTALL" == "1" ]]; then
  info "Installing Claude Code @${CLAUDE_CODE_VERSION}..."
  npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" --force
  hash -r
  ok "Claude Code ${CLAUDE_CODE_VERSION} installed"
  info "Override pinned version via CLAUDE_CODE_VERSION env var if a newer release is required"
fi

# ---- 5. Merge managed keys into ~/.claude/settings.json ----
info "Merging managed keys into ~/.claude/settings.json..."
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
cp -f "$SETTINGS" "$SETTINGS.bak.sii-agent-fleet" 2>/dev/null || true
python3 - "$SETTINGS" "$MODEL" <<'PY'
import json, sys
path, model = sys.argv[1], sys.argv[2]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except FileNotFoundError:
    data = {}
except json.JSONDecodeError:
    print(f"\033[1;33m[WARN]\033[0m existing settings.json could not be parsed; backed up at {path}.bak.sii-agent-fleet, writing fresh", file=sys.stderr)
    data = {}
data["model"] = model
data.setdefault("effortLevel", "high")
data.setdefault("theme", "dark")
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
ok "settings.json merged (model=${MODEL}); backup at ${SETTINGS}.bak.sii-agent-fleet"

# ---- 6. Write env vars + nvm init to ~/.bashrc (idempotent) ----
# Uses Python to replace the managed block portably (GNU/BSD sed differ).
info "Writing env vars to ~/.bashrc..."
BASHRC="$HOME/.bashrc"
cp -f "$BASHRC" "$BASHRC.bak.sii-agent-fleet" 2>/dev/null || true
BASE_URL="$BASE_URL" \
AUTH_TOKEN="$AUTH_TOKEN" \
CLAUDE_TGZ_SOURCE="$CLAUDE_TGZ_SOURCE" \
CLAUDE_WHEEL_DIR_SOURCE="$CLAUDE_WHEEL_DIR_SOURCE" \
BASHRC="$BASHRC" \
  python3 - <<'PY'
import os, shlex
from pathlib import Path

bashrc = Path(os.environ["BASHRC"])
base_url = os.environ["BASE_URL"]
auth_token = os.environ["AUTH_TOKEN"]
tgz = os.environ.get("CLAUDE_TGZ_SOURCE", "").strip()
wheel = os.environ.get("CLAUDE_WHEEL_DIR_SOURCE", "").strip()

BEGIN = "# >>> sii-agent-fleet env >>>"
END   = "# <<< sii-agent-fleet env <<<"

lines = []
if bashrc.exists():
    lines = bashrc.read_text(encoding="utf-8").splitlines()

# Drop any existing managed block (idempotent).
out = []
in_block = False
for ln in lines:
    if ln.strip() == BEGIN:
        in_block = True
        continue
    if ln.strip() == END:
        in_block = False
        continue
    if not in_block:
        out.append(ln)

# Build new managed block with shell-escaped values.
q = shlex.quote
block = [
    "",
    BEGIN,
    'export NVM_DIR="$HOME/.nvm"',
    '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"',
    "export CLAUDE_CODE_DISABLE_AUTOUPDATER=1",
    f"export ANTHROPIC_BASE_URL={q(base_url)}",
    f"export ANTHROPIC_AUTH_TOKEN={q(auth_token)}",
    "unset ANTHROPIC_API_KEY",
]
if tgz and wheel:
    block += [
        "export TB_CC_OPIK_ENABLE_HOOK=1",
        f"export TB_CC_CLAUDE_TGZ_SOURCE={q(tgz)}",
        f"export TB_CC_PY_WHEEL_DIR_SOURCE={q(wheel)}",
    ]
block.append(END)

out.extend(block)
bashrc.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
ok "Env vars written to ~/.bashrc (idempotent); backup at ${BASHRC}.bak.sii-agent-fleet"

export ANTHROPIC_BASE_URL="${BASE_URL}"
export ANTHROPIC_AUTH_TOKEN="${AUTH_TOKEN}"
unset ANTHROPIC_API_KEY || true
if [[ -n "${CLAUDE_TGZ_SOURCE:-}" && -n "${CLAUDE_WHEEL_DIR_SOURCE:-}" ]]; then
  export TB_CC_OPIK_ENABLE_HOOK=1
  export TB_CC_CLAUDE_TGZ_SOURCE="${CLAUDE_TGZ_SOURCE}"
  export TB_CC_PY_WHEEL_DIR_SOURCE="${CLAUDE_WHEEL_DIR_SOURCE}"
fi

# ---- 7. Clone repo ----
if [[ -d "$REPO_DIR/.git" ]]; then
  ok "Repo already exists: $REPO_DIR (skip clone)"
else
  info "Cloning repo to $REPO_DIR..."
  git clone --recurse-submodules "$REPO_URL" "$REPO_DIR"
  ok "Repo cloned"
fi
info "Syncing submodules..."
git -C "$REPO_DIR" submodule update --init --recursive || warn "Submodule sync failed (ignore if no submodules)"

if [[ ! -d "$REPO_DIR/skills" ]]; then
  err "$REPO_DIR/skills not found, repo structure looks wrong"
  exit 1
fi

# ---- 8. Install skills plugin ----
info "Installing skills plugin..."
CLAUDE_PLUGIN_DIR="$HOME/.claude/skills/sii-agent-fleet"
mkdir -p "$CLAUDE_PLUGIN_DIR/.claude-plugin"
SKILLS=(
  harbor-benchmark-runner
  openclaw-fleet-operations
  openclaw-benchmark-runners
  tui-dashboard-deployment
)
for skill in "${SKILLS[@]}"; do
  if [[ -d "$REPO_DIR/skills/$skill" ]]; then
    ln -sfn "$REPO_DIR/skills/$skill" "$CLAUDE_PLUGIN_DIR/$skill"
  else
    warn "skill dir not found: $REPO_DIR/skills/$skill"
  fi
done
cat > "$CLAUDE_PLUGIN_DIR/.claude-plugin/plugin.json" <<'JSON'
{
  "$schema": "https://anthropic.com/claude-code/plugin.schema.json",
  "name": "sii-agent-fleet",
  "version": "0.1.0",
  "description": "SII Agent Fleet operation skills for Harbor, OpenClaw, benchmarks, and TUI deployment.",
  "skills": [
    "./harbor-benchmark-runner",
    "./openclaw-fleet-operations",
    "./openclaw-benchmark-runners",
    "./tui-dashboard-deployment"
  ]
}
JSON
ok "Skills plugin installed to $CLAUDE_PLUGIN_DIR"

# ---- 9. Merge managed keys into config.local.env ----
# Update only the keys setup.sh manages (BASE_URL/API_KEY/MODEL + OPIK_*),
# preserve any other private overrides the user has added (mirrors, etc.).
# BASE_URL is stored as-is (without /v1), matching the repo convention:
# config.env documents BASE_URL as the API root without a version suffix;
# runners append /v1 themselves.
info "Merging managed keys into $REPO_DIR/config.local.env..."
CONFIG_LOCAL="$REPO_DIR/config.local.env"
cp -f "$CONFIG_LOCAL" "$CONFIG_LOCAL.bak.sii-agent-fleet" 2>/dev/null || true
BASE_URL="$BASE_URL" \
AUTH_TOKEN="$AUTH_TOKEN" \
MODEL="$MODEL" \
OPIK_URL="${OPIK_URL:-}" \
OPIK_API_KEY="${OPIK_API_KEY:-}" \
OPIK_WORKSPACE="${OPIK_WORKSPACE:-}" \
OPIK_PROJECT_NAME="${OPIK_PROJECT_NAME:-}" \
CONFIG_LOCAL="$CONFIG_LOCAL" \
  python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["CONFIG_LOCAL"])
base = os.environ["BASE_URL"].rstrip("/")
token = os.environ["AUTH_TOKEN"]
model = os.environ["MODEL"]

# Managed keys: BASE_URL stored without /v1 (repo convention; runners append it).
managed = {
    "BASE_URL": base,
    "API_KEY": token,
    "MODEL": model,
}
opik_url = os.environ.get("OPIK_URL", "").strip()
if opik_url:
    managed["OPIK_URL"] = opik_url
    managed["OPIK_API_KEY"] = os.environ.get("OPIK_API_KEY", "")
    managed["OPIK_WORKSPACE"] = os.environ.get("OPIK_WORKSPACE") or "default"
    managed["OPIK_PROJECT_NAME"] = os.environ.get("OPIK_PROJECT_NAME", "")

# Read existing lines, keep non-managed keys as-is.
existing = {}
order = []
if path.exists():
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            order.append(("comment", line.rstrip("\n")))
            continue
        if "=" in stripped:
            k, _, v = stripped.partition("=")
            existing[k] = v
            order.append(("kv", k))
        else:
            order.append(("raw", line.rstrip("\n")))

existing.update(managed)

# Emit: existing structure (comments/order preserved) + any new managed keys.
# Values are plain (unquoted) to match config.env convention; the repo's
# env-file readers (load_env_file) use partition("=") + strip() without
# shell unquoting, so quoted values would be read back with the quotes
# still embedded.
def emit(k):
    return f"{k}={existing[k]}"

seen = set()
out = []
for kind, val in order:
    if kind == "kv":
        if val in existing:
            out.append(emit(val))
            seen.add(val)
    else:
        out.append(val)
for k in managed:
    if k not in seen:
        out.append(emit(k))

path.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
ok "config.local.env merged; backup at ${CONFIG_LOCAL}.bak.sii-agent-fleet"

# ---- 10. Docker permission check ----
info "Checking Docker permission..."
if docker ps >/dev/null 2>&1; then
  ok "Docker permission OK"
else
  warn "Current user has no Docker permission, but benchmark REQUIRES Docker!"
  warn "Fix: sudo usermod -aG docker \$USER  then reopen terminal/tmux"
fi

echo
ok "========================================"
ok " Environment setup complete!"
ok "========================================"
echo
info "Idempotent: safe to re-run if something failed."
info "In a new terminal, run 'source ~/.bashrc' first."
