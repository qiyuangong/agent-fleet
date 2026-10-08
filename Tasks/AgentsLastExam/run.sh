#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/config_loader.sh"
agent_fleet_load_config "$REPO_ROOT"
export HARBOR_KUBEVIRT_GUEST_PROTOCOL=ale
export PYTHONPATH="$SCRIPT_DIR:$REPO_ROOT/Agents/utils/common/Harbor${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONDONTWRITEBYTECODE=1
exec python3 -m ale_adapter.launch "$@"
