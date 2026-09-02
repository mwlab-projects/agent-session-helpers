#!/bin/bash
# Stop hook — runs automatically at the end of each Claude Code session
# Commits and pushes changes if a commit message file exists

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
MSG_FILE="$REPO/session_commit_msg.txt"
FILES_LIST="$REPO/session_commit_files.txt"

# Skip if not in a git repo or no commit message queued
[ -n "$REPO" ] && [ -f "$MSG_FILE" ] || exit 0

ERROR_LOG="$REPO/session_error.log"

# Stage only the files the session identified as its own (written by session_save)
# — never a blanket `git add -A`, which would sweep up other concurrent sessions' in-progress
# work sharing the same working tree.
if [ -f "$FILES_LIST" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && git -C "$REPO" add -- "$f"
  done < "$FILES_LIST"
  rm "$FILES_LIST"
else
  # Abnormal case: the skill is supposed to always write this file alongside the commit
  # message. Falling back to `git add -A` (old behavior) rather than skipping the commit
  # entirely — this hook can run unsupervised, and never committing would leave changes
  # unsynced indefinitely with nobody around to notice the error log.
  git -C "$REPO" add -A
  echo "Commit scope not applied: $FILES_LIST not found, falling back to git add -A for this commit (not a sync conflict — check why the skill didn't write it)." >> "$ERROR_LOG"
fi

# Nothing staged (e.g. session touched no local file) — skip the commit
if git -C "$REPO" diff --cached --quiet; then
  rm -f "$MSG_FILE"
  exit 0
fi

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

# rebase --autostash exits 0 even when the final autostash re-application conflicts
# (the rebase itself succeeded; only the stash pop is conflicted). Detect that separately —
# never leave unmerged (UU) content in the working tree. The stash is left untouched so
# nothing is lost. The session's own commit above already happened and is unaffected — this
# only guards against leftover uncommitted state outside the normal commit flow.
CONFLICTED=$(git -C "$REPO" diff --name-only --diff-filter=U)
if [ -n "$CONFLICTED" ]; then
  git -C "$REPO" reset --hard HEAD > /dev/null 2>&1
  echo "Push skipped: rebase succeeded but autostash re-application conflicted on: $CONFLICTED. Pending state preserved in 'git stash list' (not dropped). Local commits not pushed to remote. Resolve manually next session." > "$ERROR_LOG"
  exit 0
fi

# Push
git -C "$REPO" push > /dev/null 2>&1

exit 0
