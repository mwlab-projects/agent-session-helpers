#!/bin/bash
# Stop hook — runs automatically at the end of each agent turn, in every session open in the repository.
# Commits and pushes the session commits prepared by prepare_session_commit.sh (file format described there, and only there).

# Root, git dir and the pre-commit hook git commit will run (core.hooksPath honoured), in one git call
GIT_PATHS=$(git rev-parse --show-toplevel --absolute-git-dir --git-path hooks/pre-commit 2>/dev/null)
{ IFS= read -r REPO; IFS= read -r GIT_DIR_ABS; IFS= read -r PRE_COMMIT_HOOK; } <<< "$GIT_PATHS"
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

SYNC_LIB="$REPO/_system/hooks/harness/lib/sync_git_with_remote.sh"
if [ ! -f "$SYNC_LIB" ]; then
  printf "Missing %s: session saves are neither committed nor pushed until it is restored.\n\n" "$SYNC_LIB" >> "$ERROR_LOG"
  exit 0
fi
. "$SYNC_LIB"
# Shared checks (cc_save_path), same folder
CHECK_LIB="$REPO/_system/hooks/harness/lib/commit_check_lib.sh"
if [ ! -f "$CHECK_LIB" ]; then
  grep -qF "Missing $CHECK_LIB" "$ERROR_LOG" 2>/dev/null ||
    printf "Missing %s: session saves are neither committed nor pushed until it is restored.\n\n" "$CHECK_LIB" >> "$ERROR_LOG"
  exit 0
fi
. "$CHECK_LIB"

# Lock (see hooks_lock_acquire): every open session fires this hook at the end of its turn; one run at a time,
# a run that waited finds the commit files already processed. Still busy after 45s (SESSION_LOCK_TIMEOUT, used by
# the tests): the commit files stay in place for the next turn's run.
hooks_lock_acquire "$REPO" "${SESSION_LOCK_TIMEOUT:-45}" || exit 0

LARGE_FILE_CHECK="$REPO/_system/hooks/git/large_file_check.sh"
# Large file check run once per save: by the repository's own pre-commit hook when git commit runs it, otherwise
# here before the commit (hooks not activated, or core.hooksPath pointing elsewhere)
HOOK_CHECKS_LARGE_FILES=0
# (-ef: same file, whatever the form of the path; --git-path answers relative to the current folder)
[ -f "$LARGE_FILE_CHECK" ] && [ "$PRE_COMMIT_HOOK" -ef "$REPO/_system/hooks/git/pre-commit" ] && [ -x "$PRE_COMMIT_HOOK" ] &&
  HOOK_CHECKS_LARGE_FILES=1
# Pointer added to a large file refusal in session_error.log (block of values only there, instructions in the file)
LARGE_FILE_HINT="Full instructions: _system/hooks/git/messages/large_file_instructions.md; stage the files modified while applying them (updated links, .gitattributes) with git add instead of saving again."
# One state file per refused save (see refusal_unchanged), next to the index snapshot
REFUSED_DIR="$GIT_DIR_ABS/hub-session-refused"
# A refused save is tried again anyway after this delay (transient causes: full disk, lock...)
REFUSED_RETRY_SECONDS="${SESSION_REFUSED_RETRY_SECONDS:-900}"

# Appends block $1 to session_error.log unless already there: a commit file kept after a failed commit is retried
# and may fail the same way. Compared without blank lines (the sync rewrites the log in blank-line blocks).
log_once() {
  case "$(sed '/^[[:space:]]*$/d' "$ERROR_LOG" 2>/dev/null)" in
    *"$(printf '%s\n' "$1" | sed '/^[[:space:]]*$/d')"*) ;;
    *) printf '%s\n\n' "$1" >> "$ERROR_LOG" ;;
  esac
}

# What a refused save (state file $1, paths "$2...") depends on, besides the dates of its files: last commit, whole
# index, which listed paths exist, which refused files exist (one moved out of a listed folder leaves the folder)
refusal_fingerprint() {
  local state="$1" f
  shift
  git -C "$REPO" rev-parse -q --verify HEAD
  git -C "$REPO" ls-files -s -z | cksum
  for f in "$@"; do if [ -e "$REPO/$f" ] || [ -L "$REPO/$f" ]; then printf 1; else printf 0; fi; done
  echo
  if [ -f "$state.refused" ]; then
    while IFS= read -r -d '' f; do if [ -e "$REPO/$f" ] || [ -L "$REPO/$f" ]; then printf 1; else printf 0; fi; done < "$state.refused"
  fi
  echo
}

# Records the refusal of a save of paths "$2..." in state file $1 (after the index is restored)
refusal_record() {
  local state="$1"
  shift
  mkdir -p "$REFUSED_DIR" && { date +%s; refusal_fingerprint "$state" "$@"; } > "$state"
}

# 0 when nothing a refused save (state file $1, paths "$2...") depends on has changed since its refusal: trying again
# would only redo git add, the check and the commit attempt (at every tool call under OpenCode) for the same result
refusal_unchanged() {
  local state="$1" since now f
  shift
  [ -f "$state" ] || return 1
  since=$(head -n 1 "$state")
  now=$(date +%s)
  case "$since" in ''|*[!0-9]*) return 1 ;; esac
  [ $((now - since)) -lt "$REFUSED_RETRY_SECONDS" ] || return 1
  [ "$(tail -n +2 "$state")" = "$(refusal_fingerprint "$state" "$@")" ] || return 1
  [ "$REPO/.gitattributes" -nt "$state" ] && return 1
  [ "$#" -gt 0 ] || return 0
  git -C "$REPO" --literal-pathspecs ls-files -z -co --exclude-standard -- "$@" > "$state.files" 2>/dev/null || return 1
  while IFS= read -r -d '' f; do
    [ "$REPO/$f" -nt "$state" ] && { rm -f "$state.files"; return 1; }
  done < "$state.files"
  rm -f "$state.files"
  return 0
}

# One session_error.log entry per save kept after a failure (replaced at each new failure, removed once it is saved)
refusal_log() {
  local text=""
  [ -n "$2" ] && text="Session save not committed, summary kept: it will be committed automatically once the cause is fixed (retried whenever the save's files, the index, the last commit or .gitattributes change), without saving again. Reason: $2"
  sync_log_set "$REPO" "save $1" "$text"
}

DID_WORK=0
for REQ in "$REPO"/_system/session_commit_*.txt; do
  [ -f "$REQ" ] || continue
  REQ_NAME="${REQ##*/}"
  STATE="$REFUSED_DIR/$REQ_NAME"

  # Split the commit file (format: see prepare_session_commit.sh): file paths, separator line, commit message
  SEP_LINE=$(grep -n -x -m1 -F '=== MESSAGE ===' "$REQ" | cut -d: -f1)
  if [ -z "$SEP_LINE" ]; then
    printf "Malformed session commit file (no message separator), dropped. Content:\n%s\n\n" "$(cat "$REQ")" >> "$ERROR_LOG"
    rm -f "$REQ" "$STATE" "$STATE.refused"
    continue
  fi
  # No path line when the separator is the first line (`head -n 0` is refused by BSD head)
  FILES_TEXT=""
  [ "$SEP_LINE" -gt 1 ] && FILES_TEXT=$(head -n $((SEP_LINE - 1)) "$REQ")
  MESSAGE=$(tail -n +$((SEP_LINE + 1)) "$REQ")

  # Stage only the files the session identified as its own (listed by prepare_session_commit.sh)
  # — never a blanket `git add -A`, which would sweep up other concurrent sessions' in-progress
  # work sharing the same working tree.
  LISTED=()
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
    [ -n "$f" ] || continue
    # Made relative to the root (rule: cc_save_path); outside the repository or pointing to all of it: never saved,
    # reported, the rest of the save goes on
    cc_save_path "$f" "$REPO"
    case $? in
      1) OUTSIDE_PATHS="${OUTSIDE_PATHS:-}${f}"$'\n'; continue ;;
      2) WHOLE_PATHS="${WHOLE_PATHS:-}${f}"$'\n'; continue ;;
    esac
    f=$CC_REPO_PATH
    LISTED[${#LISTED[@]}]="$f"
  done <<< "$FILES_TEXT"
  if [ -n "${OUTSIDE_PATHS:-}" ]; then
    log_once "$(printf 'Paths outside the repository, left out of the save (only files of the repository are saved):\n%s' "$OUTSIDE_PATHS")"
    OUTSIDE_PATHS=""
  fi
  if [ -n "${WHOLE_PATHS:-}" ]; then
    log_once "$(printf 'Paths pointing to the whole repository, left out of the save (a save holds the files of its session only):\n%s' "$WHOLE_PATHS")"
    WHOLE_PATHS=""
  fi

  # A gitignored path can never be legitimately added (the hook's own working files are gitignored, and an agent
  # may list them in its commit scope): skipped silently instead of logging a false add failure. One git call for
  # all paths; path by path if git refuses one of them (e.g. outside the repository).
  PATHS=()
  if [ "${#LISTED[@]}" -gt 0 ]; then
    IGNORED=()
    printf '%s\0' "${LISTED[@]}" | git -C "$REPO" check-ignore -z --stdin > "$GIT_DIR_ABS/hub-session-ignored" 2>/dev/null
    IGNORE_RC=$?
    while IFS= read -r -d '' f; do IGNORED[${#IGNORED[@]}]="$f"; done < "$GIT_DIR_ABS/hub-session-ignored"
    rm -f "$GIT_DIR_ABS/hub-session-ignored"
    for f in "${LISTED[@]}"; do
      case "$IGNORE_RC" in
        0|1) ign=0; for g in ${IGNORED[@]+"${IGNORED[@]}"}; do [ "$g" = "$f" ] && ign=1 && break; done
             [ "$ign" = 1 ] && continue ;;
        *) git -C "$REPO" check-ignore -q -- "$f" && continue ;;
      esac
      PATHS[${#PATHS[@]}]="$f"
    done
  fi

  # Refused before and nothing changed since: left waiting, nothing run (no git add, commit or sync)
  refusal_unchanged "$STATE" ${PATHS[@]+"${PATHS[@]}"} && continue
  DID_WORK=1

  # Index entries of these paths before staging, put back if the save is refused: a refused save never blocks the
  # saves of the other sessions (only what it staged is unstaged). No complete snapshot: nothing is staged.
  INDEX_SNAPSHOT="$GIT_DIR_ABS/hub-session-index-snapshot"
  if ! index_entries_save "$REPO" "$INDEX_SNAPSHOT" ${PATHS[@]+"${PATHS[@]}"}; then
    # Real reason: git's own error when git fails, otherwise the snapshot file could not be written. Recorded as a
    # refusal: tried again only once something changes (no attempt and sync at every turn)
    SNAP_ERR=""
    [ "${#PATHS[@]}" -gt 0 ] && SNAP_ERR=$(git -C "$REPO" --literal-pathspecs ls-files -s -z -- "${PATHS[@]}" 2>&1 >/dev/null)
    rm -f "$STATE.refused"
    refusal_record "$STATE" ${PATHS[@]+"${PATHS[@]}"}
    if [ -n "$SNAP_ERR" ]; then
      refusal_log "$REQ_NAME" "cannot record the index state, nothing staged: $SNAP_ERR"
    else
      refusal_log "$REQ_NAME" "cannot write the index state to $INDEX_SNAPSHOT (disk full or permissions?), nothing staged."
    fi
    continue
  fi

  # One git add for all paths; path by path only if it fails (one bad path makes git add refuse them all), to stage
  # every valid path and report the others
  FAILED=""
  BATCH_OK=0
  [ "${#PATHS[@]}" -eq 0 ] && BATCH_OK=1
  [ "$BATCH_OK" = 0 ] && git_retry_index_lock -C "$REPO" --literal-pathspecs add -- "${PATHS[@]}" >/dev/null && BATCH_OK=1
  [ "$BATCH_OK" = 1 ] || for f in "${PATHS[@]}"; do
    # Capture stderr into a variable instead of redirecting straight to $ERROR_LOG:
    # a `2>>"$ERROR_LOG"` redirection opens (and thus creates) the file on every call,
    # even when git add succeeds and writes nothing — that alone would produce a spurious
    # empty session_error.log and falsely trip the "sync error" alert at next session start.
    # Literal pathspec: "img[1].png" never stages "img1.png".
    # Retried while another git command (VS Code, an agent) briefly holds the index lock
    ADD_ERR=$(git_retry_index_lock -C "$REPO" --literal-pathspecs add -- "$f")
    if [ $? -ne 0 ]; then
      # The old side of a `git mv` (rename) is already fully staged as a deletion by the time
      # this loop runs, so `git add -- <old path>` always fails with the exact same "pathspec
      # did not match any files" as a genuine bogus/typo path — nothing is actually wrong here.
      # Only treat it as benign when the old path is really gone from the working tree (rename),
      # or when it is a file refused for its size and since moved away (data/, cloud) as asked.
      # A path that still exists on disk is a genuine add failure (e.g. encoding mismatch in an
      # unusual locale) and must never be swallowed silently — it would produce an empty commit
      # with no trace in the error log. Report it, the cases are mutually exclusive.
      if [ ! -e "$REPO/$f" ] && ! git -C "$REPO" --literal-pathspecs ls-files --error-unmatch -- "$f" >/dev/null 2>&1 &&
         { git -C "$REPO" cat-file -e "HEAD:$f" 2>/dev/null ||
           { [ -f "$STATE.refused" ] && tr '\0' '\n' < "$STATE.refused" | grep -qxF -- "$f"; }; }; then
        : # benign — already-staged deletion (rename), or a refused file moved away
      else
        FAILED="${FAILED}${f}: ${ADD_ERR}"$'\n'
      fi
    fi
  done

  # Never fail silently: a malformed path must surface via session_error.log instead of just
  # being dropped from the commit.
  if [ -n "$FAILED" ]; then
    log_once "$(printf "git add failed for these paths (not included in the commit):\n%s" "$FAILED")"
  fi

  # Large files: the git hooks' own check, block of values only (no instructions in session_error.log),
  # refused paths written to $STATE.refused.new. Run here only when git commit will not run it (see above).
  REASON=""
  mkdir -p "$REFUSED_DIR"
  rm -f "$STATE.refused.new"
  if [ "$HOOK_CHECKS_LARGE_FILES" = 0 ] && [ -f "$LARGE_FILE_CHECK" ]; then
    REASON=$(cd "$REPO" && LFC_REFUSED_OUT="$STATE.refused.new" bash "$LARGE_FILE_CHECK" --compact --staged 2>&1) && REASON=""
    [ -n "$REASON" ] && REASON="$REASON"$'\n'"$LARGE_FILE_HINT"
  fi

  if [ -z "$REASON" ]; then
    # The commit takes the whole index (deliberate): anything already staged by another tool goes in with this
    # session's files; prepare_session_commit.sh and the large file check refuse a large file staged that way.
    # Always --allow-empty: nothing staged at all (e.g. session touched no local file) still commits, so the
    # session's summary lands in git log (history lives entirely in commit messages here); no effect otherwise.
    # Message passed through a file (not stdin) so that a commit retried after an index lock gets it again
    MSG_FILE="$GIT_DIR_ABS/hub-session-commit-msg.txt"
    # A message file that cannot be written (full disk...) is never committed: it could be empty or cut short
    if ! printf '%s\n' "$MESSAGE" > "$MSG_FILE" 2>/dev/null; then
      rm -f "$MSG_FILE" 2>/dev/null
      COMMIT_OUT="cannot write the commit message to $MSG_FILE (disk full or permissions?)"
      COMMIT_RC=1
    else
      # LFC_*: read by the pre-commit hook's large file check (block only, refused paths)
      COMMIT_OUT=$(LFC_COMPACT=1 LFC_REFUSED_OUT="$STATE.refused.new" git_retry_index_lock -C "$REPO" commit --allow-empty -F "$MSG_FILE")
      COMMIT_RC=$?
      rm -f "$MSG_FILE"
    fi
    if [ "$COMMIT_RC" -ne 0 ] && [ -s "$STATE.refused.new" ]; then
      # Large files refused by the pre-commit hook: its block of values, complete
      REASON="$COMMIT_OUT"$'\n'"$LARGE_FILE_HINT"
    else
      [ -n "$COMMIT_OUT" ] && printf '%s\n' "$COMMIT_OUT"
      # Other failure (another hook, full disk...): git's output, short enough for the log
      [ "$COMMIT_RC" -ne 0 ] && REASON=$(printf '%s\n' "${COMMIT_OUT:-git commit failed without output}" | sed '/^[[:space:]]*$/d' | head -n 20)
    fi
  fi

  # Save refused: what it staged is unstaged, its commit file is kept and its log entry written; tried again once
  # something changes. The other saves and the sync go on.
  if [ -n "$REASON" ]; then
    if ! RESTORE_ERR=$(index_entries_restore "$REPO" "$INDEX_SNAPSHOT" ${PATHS[@]+"${PATHS[@]}"}); then
      REASON="$REASON - index not restored: $RESTORE_ERR"
    fi
    if [ -f "$STATE.refused.new" ]; then mv -f "$STATE.refused.new" "$STATE.refused"; else rm -f "$STATE.refused"; fi
    refusal_record "$STATE" ${PATHS[@]+"${PATHS[@]}"}
    refusal_log "$REQ_NAME" "$REASON"
    continue
  fi
  rm -f "$INDEX_SNAPSHOT" "$STATE" "$STATE.refused" "$STATE.refused.new"
  [ -f "$ERROR_LOG" ] && refusal_log "$REQ_NAME" ""

  # Delete the commit file right after its commit — prevents a double commit if the push fails later
  rm -f "$REQ"
done

# Only refused saves left unchanged and no conflict to finalize: nothing to sync (no network at every tool call)
[ "$DID_WORK" = 1 ] || [ "$CONFLICT_READY" = 1 ] || exit 0

# No remote configured (ex. RGPD-conscious local-only repo, no DPA with the git host):
# nothing to push, the local commit above already succeeded.
git -C "$REPO" remote get-url origin >/dev/null 2>&1 || exit 0

# Push, integrating origin/main without ever touching other sessions' work (see sync_git_with_remote.sh).
# The [sync] block of session_error.log always reflects the latest result: removed once the sync succeeds.
sync_git_with_remote "$REPO"
sync_log_set "$REPO" sync "$(sync_status_block)"

exit 0
