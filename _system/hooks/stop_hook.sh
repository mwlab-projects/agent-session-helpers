#!/bin/bash
# Stop hook — runs automatically at the end of each agent turn, in every session open in the repository.
# Commits and pushes the session commits prepared by prepare_session_commit.sh (file format described there, and only there).

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
ERROR_LOG="$REPO/session_error.log"

# Skip if not in a git repo or no session commit prepared
[ -n "$REPO" ] && ls "$REPO"/_system/session_commit_*.txt >/dev/null 2>&1 || exit 0

# Every open session fires this hook at the end of its turn: two runs at the same moment used to
# process the same commit file twice (duplicate empty commit, then a rejected concurrent push -> false
# "push failed" alert). One run at a time; a run that waited finds the queue already processed.
# Lock still busy after 45s: the commit files stay in place for the next turn's run.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session_lock.sh"
session_lock_acquire "$REPO" 45 || exit 0

for REQ in "$REPO"/_system/session_commit_*.txt; do
  [ -f "$REQ" ] || continue

  # Split the commit file (format: see prepare_session_commit.sh): file paths, separator line, commit message
  SEP_LINE=$(grep -n -x -m1 -F '=== MESSAGE ===' "$REQ" | cut -d: -f1)
  if [ -z "$SEP_LINE" ]; then
    printf "Malformed session commit file (no message separator), dropped. Content:\n%s\n" "$(cat "$REQ")" >> "$ERROR_LOG"
    rm -f "$REQ"
    continue
  fi
  FILES_TEXT=$(head -n $((SEP_LINE - 1)) "$REQ")
  MESSAGE=$(tail -n +$((SEP_LINE + 1)) "$REQ")

  # Stage only the files the session identified as its own (listed by prepare_session_commit.sh)
  # — never a blanket `git add -A`, which would sweep up other concurrent sessions' in-progress
  # work sharing the same working tree.
  FAILED=""
  # Handle the final line even when the file has no trailing newline: plain `while read`
  # silently skips it (read returns EOF after filling the variable, so the loop body never
  # runs) - which once dropped the last file of the session list from the commit entirely.
  while IFS= read -r f || [ -n "$f" ]; do
    # The session's file list is written by an agent process: strip the invisible characters
    # an editor/encoding can slip in (trailing CR from CRLF line endings, leading/trailing
    # spaces). Left untouched, such a path makes `git add` fail with "pathspec did not match
    # any files" on a file that plainly exists — which would silently drop the file from the
    # commit (the historical root cause of this hook producing empty commits).
    f="${f//$'\r'/}"
    f="${f#"${f%%[![:space:]]*}"}"
    f="${f%"${f##*[![:space:]]}"}"
    if [ -n "$f" ]; then
      # Capture stderr into a variable instead of redirecting straight to $ERROR_LOG:
      # a `2>>"$ERROR_LOG"` redirection opens (and thus creates) the file on every call,
      # even when git add succeeds and writes nothing — that alone would produce a spurious
      # empty session_error.log and falsely trip the "sync error" alert at next session start.
      # A gitignored path can never be legitimately added (the hook's own working
      # files are gitignored, and an agent may list them in its commit scope).
      # Skip silently instead of logging a false add failure.
      git -C "$REPO" check-ignore -q -- "$f" && continue
      ADD_ERR=$(git -C "$REPO" add -- "$f" 2>&1 >/dev/null)
      if [ $? -ne 0 ]; then
        # The old side of a `git mv` (rename) is already fully staged as a deletion by the time
        # this loop runs, so `git add -- <old path>` always fails with the exact same "pathspec
        # did not match any files" as a genuine bogus/typo path — nothing is actually wrong here.
        # Only treat it as benign when the old path is really gone from the working tree (rename).
        # A path that still exists on disk is a genuine add failure (e.g. encoding mismatch in an
        # unusual locale) and must never be swallowed silently — it would produce an empty commit
        # with no trace in the error log. Report it, the two cases are mutually exclusive.
        if [ ! -e "$REPO/$f" ] && git -C "$REPO" cat-file -e "HEAD:$f" 2>/dev/null && ! git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
          : # benign — already-staged deletion (rename), nothing to do
        else
          FAILED="${FAILED}${f}: ${ADD_ERR}"$'\n'
        fi
      fi
    fi
  done <<< "$FILES_TEXT"

  # Never fail silently: a malformed path must surface via session_error.log instead of just
  # being dropped from the commit.
  if [ -n "$FAILED" ]; then
    printf "git add failed for these paths (not included in the commit):\n%s" "$FAILED" >> "$ERROR_LOG"
  fi

  # Nothing staged (e.g. session touched no local file) — commit anyway with --allow-empty so the
  # session's summary still lands in git log (history lives entirely in commit messages here).
  # Never risks pulling in unrelated changes: an empty commit stages nothing.
  if git -C "$REPO" diff --cached --quiet; then
    printf '%s\n' "$MESSAGE" | git -C "$REPO" commit --allow-empty -F -
  else
    printf '%s\n' "$MESSAGE" | git -C "$REPO" commit -F -
  fi

  # Delete the commit file right after its commit — prevents a double commit if the push fails later
  rm -f "$REQ"
done

# No remote configured (ex. RGPD-conscious local-only hub, no DPA with the git host) —
# nothing to push, the local commit above already succeeded.
git -C "$REPO" remote get-url origin >/dev/null 2>&1 || exit 0

# Pull with rebase before pushing to handle cases where remote has advanced
# --autostash: stashes any uncommitted changes before rebasing, restores them after
# On conflict: abort rebase, skip push, write session_error.log for next session_start to handle
if git -C "$REPO" fetch origin main > /dev/null 2>&1; then
  if git -C "$REPO" merge-base --is-ancestor origin/main HEAD 2>/dev/null; then
    : # origin/main already fully contained in HEAD — nothing to integrate, skip rebase --autostash
# entirely. Avoids stashing/popping the whole working tree for no reason on every push,
    # which could desync a concurrent session's in-progress git mv.
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

# Push — capture output instead of discarding it: a silent failure here (race with a
# concurrent push, network drop, revoked deploy key...) would otherwise leave the commit
# stranded local-only with zero trace, discovered only by accident much later.
PUSH_OUTPUT=$(git -C "$REPO" push 2>&1)
if [ $? -ne 0 ]; then
  echo "Push failed after commit: the commit succeeded locally but was not pushed to remote. git output:
$PUSH_OUTPUT" > "$ERROR_LOG"
fi

exit 0
