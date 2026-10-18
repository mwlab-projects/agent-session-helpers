#!/bin/bash
# Stop hook — runs automatically at the end of each agent turn, in every session open in the repository.
# Commits and pushes the session commits prepared by prepare_session_commit.sh (file format described there, and only there).

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
ERROR_LOG="$REPO/session_error.log"

[ -n "$REPO" ] || exit 0

# Work to do: a session commit prepared, or a sync conflict whose files an agent has resolved (no conflict
# marker left in the copies of _system/sync_conflict/; the sync script finalizes it).
HAS_COMMITS=0
ls "$REPO"/_system/session_commit_*.txt >/dev/null 2>&1 && HAS_COMMITS=1
CONFLICT_READY=0
if [ -f "$REPO/_system/sync_conflict/.sync_conflict_state" ] && \
   ! grep -rqE --exclude='*.local_version' --exclude='*.remote_version' --exclude='sync_conflict_resolution_instructions.md' \
     '^(<<<<<<<|>>>>>>>)( |$)' "$REPO/_system/sync_conflict" 2>/dev/null; then
  CONFLICT_READY=1
fi
[ "$HAS_COMMITS" = 1 ] || [ "$CONFLICT_READY" = 1 ] || exit 0

SYNC_LIB="$REPO/_system/hooks/scripts/sync_git_with_remote.sh"
if [ ! -f "$SYNC_LIB" ]; then
  printf "Missing %s: session saves are neither committed nor pushed until it is restored.\n\n" "$SYNC_LIB" >> "$ERROR_LOG"
  exit 0
fi
. "$SYNC_LIB"

# Lock (see hooks_lock_acquire): every open session fires this hook at the end of its turn; one run at a time,
# a run that waited finds the commit files already processed. Still busy after 45s (SESSION_LOCK_TIMEOUT, used by
# the tests): the commit files stay in place for the next turn's run.
hooks_lock_acquire "$REPO" "${SESSION_LOCK_TIMEOUT:-45}" || exit 0

for REQ in "$REPO"/_system/session_commit_*.txt; do
  [ -f "$REQ" ] || continue

  # Split the commit file (format: see prepare_session_commit.sh): file paths, separator line, commit message
  SEP_LINE=$(grep -n -x -m1 -F '=== MESSAGE ===' "$REQ" | cut -d: -f1)
  if [ -z "$SEP_LINE" ]; then
    printf "Malformed session commit file (no message separator), dropped. Content:\n%s\n\n" "$(cat "$REQ")" >> "$ERROR_LOG"
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
      # Retried while another git command (VS Code, an agent) briefly holds the index lock
      ADD_ERR=$(git_retry_index_lock -C "$REPO" add -- "$f")
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
    printf "git add failed for these paths (not included in the commit):\n%s\n" "$FAILED" >> "$ERROR_LOG"
  fi

  # Nothing staged (e.g. session touched no local file) — commit anyway with --allow-empty so the
  # session's summary still lands in git log (history lives entirely in commit messages here).
  # Never risks pulling in unrelated changes: an empty commit stages nothing.
  # Message passed through a file (not stdin) so that a commit retried after an index lock gets it again
  MSG_FILE="$(git -C "$REPO" rev-parse --absolute-git-dir)/hub-session-commit-msg.txt"
  printf '%s\n' "$MESSAGE" > "$MSG_FILE"
  if git -C "$REPO" diff --cached --quiet; then
    git_retry_index_lock -C "$REPO" commit --allow-empty -F "$MSG_FILE"
  else
    git_retry_index_lock -C "$REPO" commit -F "$MSG_FILE"
  fi
  rm -f "$MSG_FILE"

  # Delete the commit file right after its commit — prevents a double commit if the push fails later
  rm -f "$REQ"
done

# No remote configured (ex. RGPD-conscious local-only repo, no DPA with the git host):
# nothing to push, the local commit above already succeeded.
git -C "$REPO" remote get-url origin >/dev/null 2>&1 || exit 0

# Push, integrating origin/main without ever touching other sessions' work (see sync_git_with_remote.sh).
# The [sync] block of session_error.log always reflects the latest result: removed once the sync succeeds.
sync_git_with_remote "$REPO"
sync_log_set "$REPO" sync "$(sync_status_block)"

exit 0
