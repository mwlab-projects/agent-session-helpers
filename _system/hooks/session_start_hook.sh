#!/bin/bash
# SessionStart hook — runs automatically at the beginning of each new Agent session
# Syncs the repo with origin/main and injects a context file into Claude's context

REPO=$(git rev-parse --show-toplevel 2>/dev/null)

# Skip if not in a git repo
[ -n "$REPO" ] || exit 0

ERROR_LOG="$REPO/session_error.log"

# ── Configure which file to inject as context ──────────────────────────────
# Default: CHANGELOG.md. Change to README.md or any other file if preferred.
CONTEXT_FILE="$REPO/CHANGELOG.md"
# ──────────────────────────────────────────────────────────────────────────

# Attempt to pull. On conflict: abort rebase cleanly.
PULL_FAILED=false
FETCH_OUTPUT=$(git -C "$REPO" fetch origin main 2>&1)
if git -C "$REPO" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
  # origin/main is already fully contained in local HEAD: nothing to rebase.
  # Skip --autostash entirely — it stashes/pops the whole working tree unconditionally,
  # even when the rebase itself would be a no-op.
  PULL_OUTPUT="$FETCH_OUTPUT"
  PULL_EXIT=0
else
  REBASE_OUTPUT=$(git -C "$REPO" rebase --autostash origin/main 2>&1)
  PULL_EXIT=$?
  PULL_OUTPUT="$FETCH_OUTPUT
$REBASE_OUTPUT"
fi
if [ $PULL_EXIT -ne 0 ]; then
  git -C "$REPO" rebase --abort > /dev/null 2>&1
  rm -rf "$REPO/.git/rebase-merge" "$REPO/.git/rebase-apply"
  PULL_FAILED=true
else
  # rebase --autostash exits 0 even when the final autostash re-application conflicts
  # (the rebase itself succeeded; only the stash pop is conflicted). Detect that separately —
  # never leave unmerged (UU) content in the working tree. The stash is left untouched so
  # nothing is lost.
  CONFLICTED=$(git -C "$REPO" diff --name-only --diff-filter=U)
  if [ -n "$CONFLICTED" ]; then
    git -C "$REPO" reset --hard HEAD > /dev/null 2>&1
    PULL_OUTPUT="Autostash re-application conflicted on: $CONFLICTED. Session changes preserved in 'git stash list' (not dropped)."
    PULL_FAILED=true
  fi
fi

# A stash left over from a previous session's autostash-pop conflict must never be silently
# dropped just because THIS session's pull happens to succeed cleanly (nothing local to
# re-apply this time). Keep flagging it every session until it is actually merged and dropped.
if ! $PULL_FAILED; then
  ORPHAN_STASH=$(git -C "$REPO" stash list)
  if [ -n "$ORPHAN_STASH" ]; then
    PULL_FAILED=true
    PULL_OUTPUT="Pull succeeded, but an unresolved stash from a previous session conflict is still present and was never merged:
$ORPHAN_STASH"
  fi
fi

if $PULL_FAILED; then
  # If stop hook already wrote an error (push skipped), compound the message
  if [ -f "$ERROR_LOG" ]; then
    printf "Previous session failed to push AND current pull also failed.\n\ngit output:\n%s" "$PULL_OUTPUT" > "$ERROR_LOG"
  else
    printf "git pull --rebase failed (exit %s):\n\n%s" "$PULL_EXIT" "$PULL_OUTPUT" > "$ERROR_LOG"
  fi
else
  # No pull error: remove error log if it exists
  rm -f "$ERROR_LOG"
fi

# Inject context file
if [ -f "$CONTEXT_FILE" ]; then
  FILENAME=$(basename "$CONTEXT_FILE")
  MARKER=$(echo "$FILENAME" | tr '[:lower:]' '[:upper:]' | tr '.' '_')
  echo "=== ${MARKER} START ==="
  cat "$CONTEXT_FILE"
  echo "=== ${MARKER} END ==="
  echo ""
fi

# If session_error.log exists, inject instruction for Claude
if [ -f "$ERROR_LOG" ]; then
  echo "=== SESSION_ERROR.LOG START ==="
  echo "⚠️ REPO SYNC ERROR DETECTED — content of session_error.log:"
  cat "$ERROR_LOG"
  echo ""
  echo "Instructions: run git status, git stash list, git log --oneline -5 HEAD, git log --oneline -5 origin/main. If 'git stash list' is non-empty: run 'git stash show -p' to inspect the pending content — it holds session changes that failed to merge and were never lost. Merge it manually into the current files (never silently pick a side; check with the user if the two versions genuinely conflict in meaning), commit, push, then 'git stash drop' and delete session_error.log. If 'git stash list' is empty: attempt git pull --rebase --autostash. If resolved: git push, delete session_error.log, inform user. If failing: show diverging files, propose options, never ask user to run git commands. Start with: 'Une erreur de synchronisation du repo a été détectée. Je corrige.'"
  echo "=== SESSION_ERROR.LOG END ==="
fi

exit 0
