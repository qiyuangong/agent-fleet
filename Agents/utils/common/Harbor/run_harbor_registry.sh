#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/env.sh"

set +e
"$SCRIPT_DIR/harboropik.sh"
status="$?"
set -e

if [[ "$HARBOR_ZELLIJ_CLOSE_ON_COMPLETE" != "1" ]]; then
  echo
  if [[ -f "$OUTPUT_PATH/summary.txt" ]]; then
    cat "$OUTPUT_PATH/summary.txt"
  else
    echo "summary unavailable: $OUTPUT_PATH/summary.txt"
  fi
  echo "HARBOR_ZELLIJ_CLOSE_ON_COMPLETE=0; keeping final registry pane open"
  while true; do
    sleep 3600
  done
fi

exit "$status"
