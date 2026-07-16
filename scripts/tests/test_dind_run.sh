#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROJECT_DIR="$TMP_DIR/repo"
mkdir -p "$PROJECT_DIR/scripts/dind" "$TMP_DIR/bin"
cp "$REPO_ROOT/scripts/dind-run.sh" "$PROJECT_DIR/scripts/dind-run.sh"
cp "$REPO_ROOT/scripts/run_fleet.sh" "$PROJECT_DIR/scripts/run_fleet.sh"
chmod +x "$PROJECT_DIR/scripts/dind-run.sh"
touch "$PROJECT_DIR/scripts/setup.sh"
touch "$PROJECT_DIR/scripts/dind/Dockerfile"
chmod +x "$PROJECT_DIR/scripts/setup.sh" "$PROJECT_DIR/scripts/run_fleet.sh"

cat > "$PROJECT_DIR/config.env" <<'EOF'
BASE_URL=https://config.example.com
API_KEY=sk-config
MODEL=config-model
DIND_REGISTRY_MIRRORS=https://config-mirror.invalid
DIND_DEFAULT_ADDRESS_POOLS=base=10.100.0.0/16,size=21
EOF

cat > "$PROJECT_DIR/config.local.env" <<'EOF'
BASE_URL=https://local.example.com
API_KEY=sk-local
MODEL=local-model
DIND_REGISTRY_MIRRORS="https://docker.m.daocloud.io, https://mirror.ccs.tencentyun.com"
DIND_DEFAULT_ADDRESS_POOLS="base=10.200.0.0/13,size=21;base=172.16.0.0/12,size=20"
EOF

LOG="$TMP_DIR/docker.log"
cat > "$TMP_DIR/bin/docker" <<'MOCK'
#!/usr/bin/env bash
printf 'docker'
for arg in "$@"; do
  printf ' <%s>' "$arg"
done
printf '\n'

if [[ "${1:-}" == "ps" ]]; then
  exit 0
fi
if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  exit 1
fi
if [[ "${1:-}" == "exec" && "$*" == *"docker info"* ]]; then
  exit 0
fi
exit 0
MOCK
chmod +x "$TMP_DIR/bin/docker"

PATH="$TMP_DIR/bin:$PATH" \
DIND_BOOTSTRAP=always \
HTTP_PROXY=http://proxy.invalid:8080 \
HTTPS_PROXY=http://proxy.invalid:8443 \
NO_PROXY=existing.example \
"$PROJECT_DIR/scripts/dind-run.sh" --taskset terminalbench21 --agent claude-code --workers 1 > "$LOG"

grep -q -- '--registry-mirror=https://docker.m.daocloud.io' "$LOG"
grep -q -- '--registry-mirror=https://mirror.ccs.tencentyun.com' "$LOG"
grep -q -- '--default-address-pool=base=10.200.0.0/13,size=21' "$LOG"
grep -q -- '--default-address-pool=base=172.16.0.0/12,size=20' "$LOG"
grep -q -- '<--label> <sii.agent-fleet.default-address-pools=base=10.200.0.0/13,size=21;base=172.16.0.0/12,size=20>' "$LOG"
grep -q -- '<-v> <sii-agent-fleet-dind-docker:/var/lib/docker>' "$LOG"
grep -q -- '<-v> <sii-agent-fleet-dind-home:/home/sii>' "$LOG"
grep -q -- "<-v> <$PROJECT_DIR:$PROJECT_DIR>" "$LOG"
grep -q -- '<-e> <HTTP_PROXY=http://proxy.invalid:8080>' "$LOG"
grep -q -- '<-e> <HTTPS_PROXY=http://proxy.invalid:8443>' "$LOG"
grep -q -- '<-e> <NO_PROXY=existing.example,127.0.0.1,localhost,host.docker.internal,local.example.com>' "$LOG"
grep -q -- '<-e> <no_proxy=existing.example,127.0.0.1,localhost,host.docker.internal,local.example.com>' "$LOG"
grep -q -- "<build> <--build-arg> <DIND_BASE_IMAGE=m.daocloud.io/docker.io/library/docker:28-dind> <-f> <$PROJECT_DIR/scripts/dind/Dockerfile> <-t> <sii-agent-fleet-dind:28> <$PROJECT_DIR>" "$LOG"
grep -q -- '<sii-agent-fleet-dind:28>' "$LOG"
grep -q -- '<env> <REPO_DIR='"$PROJECT_DIR"'> <BASE_URL=https://local.example.com> <API_KEY=sk-local> <MODEL=local-model>' "$LOG"
if grep -q -- '<sh> <-lc>.*apk add' "$LOG"; then
  echo "dind-run.sh installed dependencies inside the running DinD container" >&2
  exit 1
fi
grep -q -- '<./scripts/setup.sh>' "$LOG"
grep -q -- '<./scripts/run_fleet.sh> <--taskset> <terminalbench21> <--agent> <claude-code> <--workers> <1>' "$LOG"

FALLBACK_LOG="$TMP_DIR/fallback.log"
PATH="$TMP_DIR/bin:$PATH" \
container=docker \
"$PROJECT_DIR/scripts/dind-run.sh" --taskset terminalbench21 --agent claude-code --workers 1 --dry-run > "$FALLBACK_LOG" 2>&1

grep -q -- '\[WARN\] dind-run.sh cannot start DinD inside a container; running scripts/run_fleet.sh directly' "$FALLBACK_LOG"
grep -q -- 'Command: env DATASET_NAME=terminalbench21 AGENT=claude-code TB_AGENT=claude-code TOTAL_WORKERS=1 TB_N_CONCURRENT=1 bash' "$FALLBACK_LOG"
if grep -q '^docker' "$FALLBACK_LOG"; then
  echo "dind-run.sh invoked Docker after detecting a container" >&2
  exit 1
fi

PATH="$TMP_DIR/bin:$PATH" \
DIND_BOOTSTRAP=always \
DIND_REGISTRY_MIRRORS=https://override-mirror.invalid \
DIND_DEFAULT_ADDRESS_POOLS=base=10.50.0.0/16,size=21 \
"$PROJECT_DIR/scripts/dind-run.sh" --taskset terminalbench21 --agent claude-code --workers 1 > "$LOG"

grep -q -- '--registry-mirror=https://override-mirror.invalid' "$LOG"
grep -q -- '--default-address-pool=base=10.50.0.0/16,size=21' "$LOG"
if grep -q -- '--registry-mirror=https://docker.m.daocloud.io' "$LOG"; then
  echo "caller DIND_REGISTRY_MIRRORS did not override config.local.env" >&2
  exit 1
fi
if grep -q -- '--default-address-pool=base=10.200.0.0/13,size=21' "$LOG"; then
  echo "caller DIND_DEFAULT_ADDRESS_POOLS did not override config.local.env" >&2
  exit 1
fi
grep -q -- '<./scripts/run_fleet.sh> <--taskset> <terminalbench21> <--agent> <claude-code> <--workers> <1>' "$LOG"
