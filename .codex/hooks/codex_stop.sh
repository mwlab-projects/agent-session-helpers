#!/bin/bash
# Codex Stop wrapper — runs the real hub hook (commit + push), then emits
# valid JSON on stdout as Codex requires for the Stop event (plain text is invalid here)

REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -n "$REPO" ]; then
  "$REPO/_system/hooks/stop_hook.sh"
fi

echo '{}'
exit 0
