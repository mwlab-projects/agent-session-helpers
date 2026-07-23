#!/bin/bash
# Stop hook — runs automatically at the end of each Claude Code session
# Commits and pushes changes if a commit message file exists

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
MSG_FILE="$REPO/session_commit_msg.txt"

# Skip if not in a git repo or no commit message queued
[ -n "$REPO" ] && [ -f "$MSG_FILE" ] || exit 0

ERROR_LOG="$REPO/session_error.log"

# Stage all changes and commit using the queued message
git -C "$REPO" add -A
git -C "$REPO" commit -F "$MSG_FILE"

# Delete the message file right after commit — prevents double-commit if push fails later
rm "$MSG_FILE"

# Pull with rebase before pushing to handle cases where remote has advanced
# --autostash: stashes any uncommitted changes before rebasing, restores them after
# On conflict: abort rebase, skip push, write session_error.log for next session_start to handle
if ! { git -C "$REPO" fetch origin main > /dev/null 2>&1 && git -C "$REPO" rebase --autostash origin/main > /dev/null 2>&1; }; then
  git -C "$REPO" rebase --abort > /dev/null 2>&1
  rm -rf "$REPO/.git/rebase-merge" "$REPO/.git/rebase-apply"
  echo "Push skipped: pull --rebase failed before push. Local commits not pushed to remote." > "$ERROR_LOG"
  exit 0
fi

# Push
git -C "$REPO" push > /dev/null 2>&1

exit 0
