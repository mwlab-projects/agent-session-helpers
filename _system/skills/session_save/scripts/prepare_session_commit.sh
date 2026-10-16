#!/bin/bash
# Prepares the commit of a session for the Stop hook (_system/hooks/stop_hook.sh), which does the
# commit and the push. Agents never write the commit file by hand: this script guarantees its format.
#
# Usage: prepare_session_commit.sh [file ...] <<'EOF_MSG'
#        <commit message, read from stdin>
#        EOF_MSG
# No file = message-only commit (a session that just records information).
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

# Message: strip CR, then git's own cleanup (trailing spaces, repeated blank lines, edge blank lines)
MSG=$(tr -d '\r' | git stripspace)
[ -n "$MSG" ] || { echo "Empty commit message: pass it on stdin (heredoc), first line = title." >&2; exit 2; }

# Files: strip CR and surrounding spaces, drop blanks and duplicates, keep order
FILES=()
for arg in "$@"; do
  f="${arg//$'\r'/}"
  f="${f#"${f%%[![:space:]]*}"}"
  f="${f%"${f##*[![:space:]]}"}"
  [ -n "$f" ] || continue
  dup=false
  for known in ${FILES[@]+"${FILES[@]}"}; do [ "$known" = "$f" ] && dup=true && break; done
  $dup || FILES+=("$f")
done

# Every path must exist, or be known to git (a deletion or the old side of a rename is legitimate)
BAD=""
for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -e "$REPO/$f" ] || [ -e "$f" ] && continue
  git -C "$REPO" cat-file -e "HEAD:$f" 2>/dev/null && continue
  git -C "$REPO" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue
  BAD="${BAD}${f}"$'\n'
done
if [ -n "$BAD" ]; then
  printf "Unknown path(s), nothing prepared:\n%s-> fix them (repo-relative, check with git status) and run again.\n" "$BAD" >&2
  exit 2
fi

DIR="$REPO/_system"
NAME="session_commit_$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
{
  for f in ${FILES[@]+"${FILES[@]}"}; do printf '%s\n' "$f"; done
  printf '%s\n%s\n' "$SEP" "$MSG"
} > "$DIR/$NAME.tmp" && mv "$DIR/$NAME.tmp" "$DIR/$NAME.txt" || { rm -f "$DIR/$NAME.tmp"; echo "Could not write the commit file." >&2; exit 2; }
exit 0
