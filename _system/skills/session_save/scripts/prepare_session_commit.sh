#!/bin/bash
# Prepares the commit of a session for the Stop hook (_system/hooks/harness/stop_hook.sh), which does the
# commit and the push. Agents never write the commit file by hand: this script guarantees its format.
#
# Usage: prepare_session_commit.sh [file ...] <<'EOF_MSG'
#        <commit message, read from stdin>
#        EOF_MSG
# No file = message-only commit (a session that just records information).
#
# Large file check, run now while the agent is present (the commit happens later, agent absent): the git hooks' own
# check (_system/hooks/git/large_file_check.sh --save, skipped when the repository has no _system/hooks/git/) on the
# listed files and on anything already staged; a refusal prints its message, exit 2, nothing written.
#
# Commit file format (single file, the ONLY description of it - stop_hook.sh reads exactly this):
#   _system/session_commit_<timestamp>-<pid>-<random>.txt
#   line 1..n  : one repo-relative path per line (may be none)
#   next line  : exactly "=== MESSAGE ==="
#   the rest   : the commit message
# One file per session save: concurrent sessions never overwrite each other, and the file is renamed
# into place only once complete, so the hook never reads a half-written one.
#
# Silent on success. On error: a message on stderr saying what to fix, exit 2, nothing written.

REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository." >&2; exit 2; }
SEP="=== MESSAGE ==="
LARGE_FILE_CHECK_DIR="$REPO/_system/hooks/git"
# Shared checks (cc_save_path), next to the libs of the session hooks
CHECK_LIB="$REPO/_system/hooks/harness/lib/commit_check_lib.sh"
[ -f "$CHECK_LIB" ] || { echo "Missing $CHECK_LIB: restore it, nothing prepared." >&2; exit 2; }
. "$CHECK_LIB"

# Message: CR removed, then the cleanup of git stripspace, in bash (no process): trailing whitespace removed,
# repeated blank lines collapsed, leading and trailing blank lines dropped
MSG="" BLANK=0
while IFS= read -r line || [ -n "$line" ]; do
  line=${line//$'\r'/}
  line=${line%"${line##*[!$' \t']}"}
  if [ -z "$line" ]; then [ -n "$MSG" ] && BLANK=1; continue; fi
  [ "$BLANK" = 1 ] && MSG="$MSG"$'\n'
  BLANK=0
  MSG="${MSG:+$MSG$'\n'}$line"
done
[ -n "$MSG" ] || { echo "Empty commit message: pass it on stdin (heredoc), first line = title." >&2; exit 2; }

# Files: strip CR and surrounding spaces, drop blanks, made relative to the root (rule cc_save_path: a path outside
# the repository or pointing to all of it is never saved), drop duplicates, keep order
FILES=()
OUTSIDE=""
WHOLE=""
for arg in "$@"; do
  f="${arg//$'\r'/}"
  f="${f#"${f%%[![:space:]]*}"}"
  f="${f%"${f##*[![:space:]]}"}"
  [ -n "$f" ] || continue
  cc_save_path "$f" "$REPO"
  case $? in
    1) OUTSIDE="${OUTSIDE}${f}"$'\n'; continue ;;
    2) WHOLE="${WHOLE}${f}"$'\n'; continue ;;
  esac
  f=$CC_REPO_PATH
  dup=false
  for known in ${FILES[@]+"${FILES[@]}"}; do [ "$known" = "$f" ] && dup=true && break; done
  $dup || FILES+=("$f")
done
[ -n "$OUTSIDE" ] &&
  printf 'Path(s) outside the repository, nothing prepared:\n%s-> list only files of the repository, and run again.\n' "$OUTSIDE" >&2
[ -n "$WHOLE" ] &&
  printf 'Path(s) pointing to the whole repository, nothing prepared:\n%s-> list the files of this session one by one, and run again.\n' "$WHOLE" >&2
[ -z "$OUTSIDE$WHOLE" ] || exit 2

# Every path must exist, or be known to git (a deletion or the old side of a rename is legitimate)
BAD=""
for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -e "$REPO/$f" ] || [ -e "$f" ] && continue
  git -C "$REPO" cat-file -e "HEAD:$f" 2>/dev/null && continue
  git -C "$REPO" --literal-pathspecs ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue
  BAD="${BAD}${f}"$'\n'
done
if [ -n "$BAD" ]; then
  printf "Unknown path(s), nothing prepared:\n%s-> fix them (repo-relative, check with git status) and run again.\n" "$BAD" >&2
  exit 2
fi

# Large files: the git hooks' own check on the commit this save will make (listed files, plus anything already
# staged: the Stop hook commits the whole index); it prints its own message
if [ -d "$LARGE_FILE_CHECK_DIR" ]; then
  if [ ! -f "$LARGE_FILE_CHECK_DIR/large_file_check.sh" ]; then
    echo "Missing $LARGE_FILE_CHECK_DIR/large_file_check.sh: restore it, nothing prepared." >&2
    exit 2
  fi
  bash "$LARGE_FILE_CHECK_DIR/large_file_check.sh" --save -- ${FILES[@]+"${FILES[@]}"} || exit 2
fi

DIR="$REPO/_system"
NAME="session_commit_$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
{
  for f in ${FILES[@]+"${FILES[@]}"}; do printf '%s\n' "$f"; done
  printf '%s\n%s\n' "$SEP" "$MSG"
} > "$DIR/$NAME.tmp" && mv "$DIR/$NAME.tmp" "$DIR/$NAME.txt" || { rm -f "$DIR/$NAME.tmp"; echo "Could not write the commit file." >&2; exit 2; }
exit 0
