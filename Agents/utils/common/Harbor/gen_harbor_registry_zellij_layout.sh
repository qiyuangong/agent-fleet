#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

OUT="${1:-$LAYOUT_FILE}"
mkdir -p "$(dirname "$OUT")"

cat > "$OUT" <<'EOF'
layout {
  default_tab_template {
    pane size=1 borderless=true {
      plugin location="zellij:tab-bar"
    }
    children
    pane size=2 borderless=true {
      plugin location="zellij:status-bar"
    }
  }

  tab name="registry-run" focus=true {
    pane {
      command "./run_harbor_registry.sh"
      close_on_exit true
    }
  }
}
EOF

echo "Wrote registry layout to $OUT"
