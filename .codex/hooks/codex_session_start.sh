#!/bin/bash
# Codex SessionStart wrapper — runs the real hub hook and wraps its plain-text
# output into the JSON shape Codex expects (hookSpecificOutput.additionalContext)

REPO="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] || { echo '{}'; exit 0; }

CONTEXT=$("$REPO/_system/hooks/session_start_hook.sh")

jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
exit 0
