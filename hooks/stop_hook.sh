#!/bin/bash
# Stop hook — runs automatically at the end of each Agent session
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
  FAILED=""
  while IFS= read -r f; do
    if [ -n "$f" ]; then
      # Capture stderr into a variable instead of redirecting straight to $ERROR_LOG:
      # a `2>>"$ERROR_LOG"` redirection opens (and thus creates) the file on every call,
      # even when git add succeeds and writes nothing — that alone would produce a spurious
      # empty session_error.log and falsely trip the "sync error" alert at next session start.
      ADD_ERR=$(git -C "$REPO" add -- "$f" 2>&1 >/dev/null)
      if [ $? -ne 0 ]; then
        # The old side of a `git mv` (rename) is already fully staged as a deletion by the time
        # this loop runs, so `git add -- <old path>` always fails with the exact same "pathspec
        # did not match any files" as a genuine bogus/typo path — nothing is actually wrong here.
        # Only treat it as a real failure when the path never existed in HEAD either (true bogus
        # path): a path that existed in HEAD but is no longer in the index is an already-handled
        # rename, not an error.
        if git -C "$REPO" cat-file -e "HEAD:$f" 2>/dev/null && ! git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
          : # benign — already-staged deletion, nothing to do
        else
          FAILED="${FAILED}${f}: ${ADD_ERR}"$'\n'
        fi
      fi
    fi
  done < "$FILES_LIST"
  rm "$FILES_LIST"
  # Never fail silently: a malformed path (e.g. a future regression in how the skill lists
  # files) must surface via session_error.log instead of just being dropped from the commit.
  if [ -n "$FAILED" ]; then
    printf "git add a échoué pour ces chemins (non inclus dans le commit) :\n%s" "$FAILED" >> "$ERROR_LOG"
  fi
else
  # Abnormal case: the skill is supposed to always write this file alongside the commit
  # message. Falling back to `git add -A` (old behavior) rather than skipping the commit
  # entirely — this hook can run unsupervised, and never committing would leave changes
  # unsynced indefinitely with nobody around to notice the error log.
  git -C "$REPO" add -A
  echo "Commit scope not applied: $FILES_LIST not found, falling back to git add -A for this commit (not a sync conflict — check why the skill didn't write it)." >> "$ERROR_LOG"
fi

# Nothing staged (e.g. session touched no local file) — commit anyway with --allow-empty so the
# session's summary still lands in git log (history lives entirely in commit messages here).
# Never risks pulling in unrelated changes: an empty commit stages nothing.
if git -C "$REPO" diff --cached --quiet; then
  git -C "$REPO" commit --allow-empty -F "$MSG_FILE"
else
  git -C "$REPO" commit -F "$MSG_FILE"
fi

# Delete the message file right after commit — prevents double-commit if push fails later
rm "$MSG_FILE"

# Pull with rebase before pushing to handle cases where remote has advanced
# --autostash: stashes any uncommitted changes before rebasing, restores them after
# On conflict: abort rebase, skip push, write session_error.log for next session_start to handle
if git -C "$REPO" fetch origin main > /dev/null 2>&1; then
  if git -C "$REPO" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    : # origin/main already fully contained in HEAD — nothing to integrate, skip rebase --autostash
      # entirely. Avoids stashing/popping the whole working tree for no reason on every push.
  elif ! git -C "$REPO" rebase --autostash origin/main > /dev/null 2>&1; then
    git -C "$REPO" rebase --abort > /dev/null 2>&1
    rm -rf "$REPO/.git/rebase-merge" "$REPO/.git/rebase-apply"
    echo "Push skipped: pull --rebase failed before push. Local commits not pushed to remote." > "$ERROR_LOG"
    exit 0
  fi
else
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
