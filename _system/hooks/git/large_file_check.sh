#!/bin/bash
# Size limit, in bytes (size as git stores the file): the only place of this value (scripts, tests and the block of
# values shown on a refusal derive from it)
LFC_MAX_BYTES=1000000

# Large file check: the single implementation of the rule, run by the pre-commit and pre-merge-commit hooks, by
# prepare_session_commit.sh and by stop_hook.sh.
#
# Rule: a file of the commit larger than LFC_MAX_BYTES, added or modified (deletions ignored), is refused, unless:
#   - its exact content (same blob) is already in HEAD, at any path: a file accepted once is never blocked again
#     (rename, move, copy, mode change); a changed content is checked;
#   - it has the attribute allow-large-file set (pass line in .gitattributes, read as it will be committed; any other
#     value is refused);
#   - it lies under the data/ folder at the root of the repository.
# Not covered: git cherry-pick, revert and rebase (they run no hook), git commit --no-verify.
#
# Output on a refusal (stderr):
#   1) a block of values computed by the script, hard-coded in English (cc_refusal_block, _system/hooks/harness/lib/
#      commit_check_lib.sh), one entry per refused file: path, size and limit (MB: decimal, one decimal rounded up,
#      decimal comma), .gitattributes pass line, command removing it from the index, .gitignore line (root .gitignore
#      only, a tracked file must also be removed with the command; "none possible" for a name with a line break);
#   2) then instructions/large_file_instructions.md, the instructions for the agent: entirely free text, printed as it is
#      (only CRLF line endings turned into LF); the script replaces nothing in it. Missing: the block is still shown,
#      followed by a line naming the missing file.
# In session_error.log (--compact) only the block is written; stop_hook.sh adds the path of the instructions.
#
# Usage (from anywhere inside the repository):
#   large_file_check.sh [--compact] --staged      the index being committed (honours GIT_INDEX_FILE, set by git for
#                                                 the hooks), sizes and .gitattributes from that index
#   large_file_check.sh [--compact] --save [--] <path>...
#                                                 the commit a session save will make: current index plus the files
#                                                 under these paths, staged in a temporary index the way git add
#                                                 would (clean filters, CRLF conversion), new blobs in a temporary
#                                                 object folder
#   --compact (or LFC_COMPACT=1, set by stop_hook.sh for the pre-commit hook): the block only, without the
#   instructions (for session_error.log). Options in any order.
#   LFC_REFUSED_OUT=<file>: the refused paths are also written there, NUL-separated
# Exit: 0 nothing refused; 1 refused (message on stderr); 2 error (on stderr; the hooks then refuse too).
# Requires git >= 2.13 (quoted patterns in .gitattributes, rev-parse --absolute-git-dir); the pre-merge-commit hook
# needs git >= 2.24. Uses no find/xargs/wc/stat: same behaviour with Git Bash (Windows), GNU and BSD tools.

LFC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LFC_MESSAGE="$LFC_DIR/instructions/large_file_instructions.md"
LFC_LIB="$LFC_DIR/../harness/lib/commit_check_lib.sh"

# Absolute form of a path printed by git (relative to the folder the script started in, or already absolute, also
# C:/... on Windows)
lfc_abs() {
  case "$1" in /*|[A-Za-z]:*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac
}

# Temporary index = current index + the files of a save of paths "$@"; exports GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY
# and GIT_ALTERNATE_OBJECT_DIRECTORIES so that the next git commands see the commit the save will make
lfc_simulate_save() {
  local idx="$LFC_INDEX" objects="$LFC_OBJECTS" status path files=() q
  if [ -f "$idx" ]; then cp "$idx" "$LFC_TMP/index" || { echo "large_file_check: cannot copy the index." >&2; return 2; }; fi
  mkdir -p "$LFC_TMP/objects" || return 2
  cc_list_save_files "$LFC_TMP/list" "$@" || { echo "large_file_check: cannot list the files of the save." >&2; return 2; }
  while IFS= read -r -d '' status && IFS= read -r -d '' path; do
    # A folder here is a nested repository (gitlink), kept as the index has it, or a tracked file that became a
    # folder, whose entry gives way to the files under it (--replace below)
    [ -d "$path" ] && [ ! -L "$path" ] && continue
    files[${#files[@]}]="$path"
  done < "$LFC_TMP/list"
  # Alternate object folder quoted (C style): a path holding the separator (":" or ";") stays one entry
  q=${objects//\\/\\\\}
  export GIT_INDEX_FILE="$LFC_TMP/index" GIT_OBJECT_DIRECTORY="$LFC_TMP/objects"
  export GIT_ALTERNATE_OBJECT_DIRECTORIES="\"${q//\"/\\\"}\""
  [ "${#files[@]}" -gt 0 ] || return 0
  # --replace: a tracked file that became a folder (notes -> notes/a.md) gives way to the files under it, as git add
  printf '%s\0' "${files[@]}" | git update-index --add --remove --replace -z --stdin > "$LFC_TMP/update.out" 2>&1 ||
    { echo "large_file_check: cannot read the files of the save: $(cat "$LFC_TMP/update.out")" >&2; return 2; }
}

# Files over the limit in the index (GIT_INDEX_FILE) compared with HEAD (the empty tree before the first commit)
# -> CC_PATHS / CC_SIZES
lfc_collect_staged() {
  local meta path list=() shas=() size i=0
  git diff --cached --raw -z --no-renames --no-abbrev --diff-filter=ACMRT -- > "$LFC_TMP/diff" ||
    { echo "large_file_check: git diff failed." >&2; return 2; }
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    # meta = ":<old mode> <new mode> <old sha> <new sha> <status>"; gitlinks and symlinks hold no file content
    set -- $meta
    case "$2" in 160000|120000) continue ;; esac
    # data/ at the root: the place the message sends large files to (added with git add -f, or tracked already)
    case "$path" in data/*) continue ;; esac
    list[${#list[@]}]="$path"
    shas[${#shas[@]}]="$4"
  done < "$LFC_TMP/diff"
  [ "${#list[@]}" -gt 0 ] || return 0
  printf '%s\n' "${shas[@]}" | git cat-file --batch-check='%(objectsize)' > "$LFC_TMP/sizes" ||
    { echo "large_file_check: git cat-file failed." >&2; return 2; }
  while IFS= read -r size; do
    case "$size" in ''|*[!0-9]*) echo "large_file_check: cannot read the size of ${list[$i]}." >&2; return 2 ;; esac
    if [ "$size" -gt "$LFC_MAX_BYTES" ]; then
      CC_PATHS[${#CC_PATHS[@]}]="${list[$i]}"
      CC_SIZES[${#CC_SIZES[@]}]="$size"
      LFC_SHAS[${#LFC_SHAS[@]}]="${shas[$i]}"
    fi
    i=$((i + 1))
  done < "$LFC_TMP/sizes"
  [ "$i" -eq "${#list[@]}" ] || { echo "large_file_check: incomplete size list." >&2; return 2; }
}

# Keeps in CC_PATHS / CC_SIZES the files whose content (blob LFC_SHAS) is not in HEAD at any path: a file committed
# once (accepted then, or before the rule) passes when renamed, moved, copied or with a new mode; a changed content is
# a new blob, still checked. One git call, only when a file is over the limit. No HEAD (first commit) or git ls-tree
# failing: nothing dropped.
lfc_drop_in_head() {
  local rec sha found=" " keep_p=() keep_s=() i=0
  [ "${#CC_PATHS[@]}" -gt 0 ] || return 0
  git ls-tree -r -z HEAD > "$LFC_TMP/head" 2>/dev/null || return 0
  # Records "<mode> <type> <sha>\t<path>"
  while IFS= read -r -d '' rec; do
    sha=${rec#* * }; sha=${sha%%$'\t'*}
    case " ${LFC_SHAS[*]} " in *" $sha "*) found="$found$sha " ;; esac
  done < "$LFC_TMP/head"
  while [ "$i" -lt "${#CC_PATHS[@]}" ]; do
    case "$found" in
      *" ${LFC_SHAS[$i]} "*) ;;
      *) keep_p[${#keep_p[@]}]="${CC_PATHS[$i]}"; keep_s[${#keep_s[@]}]="${CC_SIZES[$i]}" ;;
    esac
    i=$((i + 1))
  done
  CC_PATHS=(${keep_p[@]+"${keep_p[@]}"})
  CC_SIZES=(${keep_s[@]+"${keep_s[@]}"})
}

# Keeps in CC_PATHS / CC_SIZES the files whose allow-large-file attribute is not exactly "set" (.gitattributes of
# the index: the version that will be committed)
lfc_drop_allowed() {
  local path attr value keep_p=() keep_s=() i=0
  [ "${#CC_PATHS[@]}" -gt 0 ] || return 0
  printf '%s\0' "${CC_PATHS[@]}" | git check-attr --cached -z --stdin "$CC_PASS_ATTR" > "$LFC_TMP/attrs" ||
    { echo "large_file_check: git check-attr failed." >&2; return 2; }
  while IFS= read -r -d '' path && IFS= read -r -d '' attr && IFS= read -r -d '' value; do
    if [ "$value" != set ]; then
      keep_p[${#keep_p[@]}]="${CC_PATHS[$i]}"
      keep_s[${#keep_s[@]}]="${CC_SIZES[$i]}"
    fi
    i=$((i + 1))
  done < "$LFC_TMP/attrs"
  [ "$i" -eq "${#CC_PATHS[@]}" ] || { echo "large_file_check: incomplete attribute list." >&2; return 2; }
  CC_PATHS=(${keep_p[@]+"${keep_p[@]}"})
  CC_SIZES=(${keep_s[@]+"${keep_s[@]}"})
}

lfc_main() {
  local compact="" mode="" rc=0 line
  # Options in any order; the paths of --save come after them (or after --)
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --compact) compact=compact; shift ;;
      --staged|--save) mode="$1"; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done
  [ -n "${LFC_COMPACT:-}" ] && compact=compact
  if [ ! -f "$LFC_LIB" ]; then echo "large_file_check: missing $LFC_LIB (restore it)." >&2; return 2; fi
  . "$LFC_LIB"
  CC_PATHS=() CC_SIZES=() LFC_SHAS=()
  # Work files in the git dir: always writable and local, whatever TMPDIR holds (e.g. a Windows path)
  LFC_TMP=$(mktemp -d "$LFC_GIT_DIR/large_file_check.XXXXXX") ||
    { echo "large_file_check: cannot create a work folder in the git dir." >&2; return 2; }
  case "$mode" in
    --staged) ;;
    --save) lfc_simulate_save "$@" || rc=$? ;;
    *) echo "Usage: large_file_check.sh [--compact] --staged | --save [--] <path>..." >&2; rc=2 ;;
  esac
  [ "$rc" -eq 0 ] && { lfc_collect_staged || rc=$?; }
  [ "$rc" -eq 0 ] && lfc_drop_in_head
  [ "$rc" -eq 0 ] && { lfc_drop_allowed || rc=$?; }
  if [ "$rc" -eq 0 ] && [ "${#CC_PATHS[@]}" -gt 0 ]; then
    rc=1
    [ -n "${LFC_REFUSED_OUT:-}" ] && printf '%s\0' "${CC_PATHS[@]}" > "$LFC_REFUSED_OUT"
    CC_MAX_BYTES=$LFC_MAX_BYTES cc_refusal_block >&2
    if [ -n "$compact" ]; then
      :
    elif [ -f "$LFC_MESSAGE" ]; then
      echo >&2
      # As it is, LF line endings even from a CRLF checkout
      while IFS= read -r line || [ -n "$line" ]; do printf '%s\n' "${line%$'\r'}"; done < "$LFC_MESSAGE" >&2
    else
      echo "Instructions file not found: $LFC_MESSAGE (restore it)." >&2
    fi
  fi
  rm -rf "$LFC_TMP"
  return "$rc"
}

# Every location the check needs, in one git call (the index and objects paths honour GIT_INDEX_FILE and
# GIT_OBJECT_DIRECTORY), then the root of the working tree: paths are repo-relative
LFC_INFO=$(git rev-parse --show-toplevel --absolute-git-dir --git-path index --git-path objects 2>/dev/null) &&
  { IFS= read -r LFC_TOP; IFS= read -r LFC_GIT_DIR; IFS= read -r LFC_INDEX; IFS= read -r LFC_OBJECTS; } <<< "$LFC_INFO" &&
  LFC_INDEX=$(lfc_abs "$LFC_INDEX") && LFC_OBJECTS=$(lfc_abs "$LFC_OBJECTS") && [ -n "$LFC_OBJECTS" ] &&
  cd "$LFC_TOP" 2>/dev/null || { echo "large_file_check: not inside a git working tree." >&2; exit 2; }
lfc_main "$@"
exit $?
