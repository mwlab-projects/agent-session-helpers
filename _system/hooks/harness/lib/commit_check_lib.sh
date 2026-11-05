#!/bin/bash
# Checks run before a commit, sourced, never run: the paths a save may hold (prepare_session_commit.sh, stop_hook.sh),
# the files it will commit and the block of values shown on a large file refusal (_system/hooks/git/large_file_check.sh).
# Run from the root of the working tree. Compatible with bash 3.2.

CC_PASS_ATTR=allow-large-file

# Path $1 of a save, as relative to the root $2 of the repository (as git prints it) -> CC_REPO_PATH, "." for the root
# itself; returns 1 when it lies outside the repository (used by cc_save_path below). A plain relative path is kept
# as it is. Any other one (absolute, also
# C:/ or C:\ on Windows, or holding ".", ".." or "//") is made absolute and resolved lexically, then compared with the
# root as git writes it; failing that, with the physical forms (one subshell, no git): the root's, and the path's
# through its nearest existing folder (symbolic links such as /tmp -> /private/tmp, a deleted file or folder, /c/...
# vs C:/... under Git Bash).
cc_repo_path() {
  local p="$1" root="$2" anc tail phys rootp
  case "$p" in
    /*|[A-Za-z]:[/\\]*) ;;
    *) case "/$p/" in */./*|*/../*|*//*) ;; *) CC_REPO_PATH=$p; return 0 ;; esac ;;
  esac
  case "$p" in [A-Za-z]:[/\\]*) p=${p//\\//} ;; /*) ;; *) p="$root/$p" ;; esac
  _cc_norm "$p"; p=$CC_NORM
  _cc_under "$p" "$root" && return 0
  anc=$p tail=""
  while [ ! -d "$anc" ]; do
    case "$anc" in */*) ;; *) return 1 ;; esac
    tail="/${anc##*/}$tail"; anc=${anc%/*}; [ -n "$anc" ] || anc=/
  done
  phys=$(cd "$root" 2>/dev/null && pwd -P && cd "$anc" 2>/dev/null && pwd -P) || return 1
  rootp=${phys%%$'\n'*}; phys=${phys#*$'\n'}; phys="${phys%/}$tail"
  _cc_under "$p" "$rootp" || _cc_under "$phys" "$rootp" || _cc_under "$phys" "$root"
}

# Path $1 of a save, checked against the root $2: 0 = a path of the repository (CC_REPO_PATH, relative to the root),
# 1 = outside the repository, 2 = the whole repository (".", "./", "x/..", the root as an absolute path, also through
# a symbolic link): a save holds the files of its session only. The single rule for prepare_session_commit.sh (refuses
# the save) and stop_hook.sh (leaves the path out); a folder of the repository stays accepted.
cc_save_path() {
  cc_repo_path "$1" "$2" || return 1
  [ "$CC_REPO_PATH" != . ] || return 2
}

# Lexical form of absolute path $1: ".", ".." and repeated "/" resolved, no final "/" -> CC_NORM
_cc_norm() {
  local p="$1" prefix="" out="" comp
  case "$p" in [A-Za-z]:/*) prefix=${p%%/*}; p=${p#*/} ;; *) p=${p#/} ;; esac
  while [ -n "$p" ]; do
    comp=${p%%/*}
    case "$p" in */*) p=${p#*/} ;; *) p="" ;; esac
    case "$comp" in
      ''|.) ;;
      ..) case "$out" in */*) out=${out%/*} ;; *) out="" ;; esac ;;
      *) out="${out:+$out/}$comp" ;;
    esac
  done
  CC_NORM="$prefix/$out"
}

# Absolute path $1 under root $2 -> CC_REPO_PATH relative to it ("." for the root itself); returns 1 otherwise
_cc_under() {
  case "$1" in
    "$2") CC_REPO_PATH=. ;;
    "$2"/*) CC_REPO_PATH=${1#"$2"/} ;;
    *) return 1 ;;
  esac
}

# Files a save of the repo-relative paths "$2..." changes, written to file $1 as NUL-separated "status\0path\0"
# records, from a single git status (no index write, GIT_OPTIONAL_LOCKS=0): M for a tracked file changed in the index or the working tree
# (D if deleted, both sides of a staged rename listed), "?" for an untracked file (ignored files excluded). Paths are
# literal (never globs) and may be folders. Returns 1 if git fails.
cc_list_save_files() {
  local out="$1" rec path xy n
  shift
  : > "$out" || return 1
  [ "$#" -gt 0 ] || return 0
  GIT_OPTIONAL_LOCKS=0 git --literal-pathspecs status --porcelain=v2 -z --untracked-files=all -- "$@" > "$out.status" ||
    { rm -f "$out.status"; return 1; }
  # Records: "1 XY <6 fields> path", "2 XY <7 fields> path" then "origPath", "u XY <8 fields> path", "? path"
  while IFS= read -r -d '' rec; do
    case "$rec" in
      '? '*) printf '?\0%s\0' "${rec#? }" ;;
      [12u]' '*)
        xy=${rec:2:2}
        case "$rec" in 1*) n=8 ;; 2*) n=9 ;; *) n=10 ;; esac
        path=$rec
        while [ "$n" -gt 0 ]; do path=${path#* }; n=$((n - 1)); done
        case "$xy" in *D*) printf 'D\0%s\0' "$path" ;; *) printf 'M\0%s\0' "$path" ;; esac
        case "$rec" in 2*) IFS= read -r -d '' path && printf 'D\0%s\0' "$path" ;; esac ;;
    esac
  done < "$out.status" >> "$out"
  rm -f "$out.status"
}

# ---------------------------------------------------------------- per-file values of the messages

# Size $1 (bytes) in decimal MB (10^6 bytes, as Finder and Explorer show it), rounded up to one decimal so that a file
# just over a limit given in whole tenths of MB never shows the limit itself; decimal comma
cc_size_mb() {
  local t=$((($1 + 99999) / 100000))
  printf '%d,%d' $((t / 10)) $((t % 10))
}

# Pass line of repo-relative path $1 for .gitattributes: glob characters escaped, "/" anchoring at the root (also
# neutralises a leading # or !), C-style quotes (git >= 2.13)
cc_pass_line() {
  local LC_ALL=C p="$1" glob="" quoted="" c i
  for ((i = 0; i < ${#p}; i++)); do
    c="${p:i:1}"
    case "$c" in '\'|'*'|'?'|'['|']') glob="$glob\\$c" ;; *) glob="$glob$c" ;; esac
  done
  glob="/$glob"
  for ((i = 0; i < ${#glob}; i++)); do
    c="${glob:i:1}"
    case "$c" in
      '\'|'"') quoted="$quoted\\$c" ;;
      $'\t') quoted="$quoted\\t" ;;
      $'\n') quoted="$quoted\\n" ;;
      $'\r') quoted="$quoted\\r" ;;
      *) quoted="$quoted$c" ;;
    esac
  done
  printf '"%s" %s' "$quoted" "$CC_PASS_ATTR"
}

# $1 quoted for a POSIX shell, on one line: single quotes, or $'...' when it holds a control character
cc_shell_quote() {
  local LC_ALL=C p="$1" out="" c i
  case "$p" in
    *[$'\n\t\r']*)
      for ((i = 0; i < ${#p}; i++)); do
        c="${p:i:1}"
        case "$c" in
          '\'|"'") out="$out\\$c" ;;
          $'\n') out="$out\\n" ;;
          $'\t') out="$out\\t" ;;
          $'\r') out="$out\\r" ;;
          *) out="$out$c" ;;
        esac
      done
      printf "\$'%s'" "$out" ;;
    *)
      for ((i = 0; i < ${#p}; i++)); do
        c="${p:i:1}"
        if [ "$c" = "'" ]; then out="$out'\\''"; else out="$out$c"; fi
      done
      printf "'%s'" "$out" ;;
  esac
}

# Command removing repo-relative path $1 from the index only (file kept on disk), without effect if git does not
# know it. Pathspec magic: "top" = relative to the root, whatever the current folder; "literal" = never matches
# another file
cc_untrack_command() {
  printf 'git rm --cached -q --ignore-unmatch -- %s' "$(cc_shell_quote ":(top,literal)$1")"
}

# .gitignore line excluding exactly repo-relative path $1 (gitignore(5)): "/" in front (anchored at the root, also
# neutralises a leading # or !), glob characters escaped with a backslash (\ * ? [ ]), trailing spaces escaped one by
# one (git drops unescaped ones). Returns 1 without output when a .gitignore line cannot hold the name (newline,
# carriage return): CC_IGNORE_NONE is then shown instead.
CC_IGNORE_NONE="none possible (line break in the name)"
cc_ignore_line() {
  local LC_ALL=C p="$1" out="" trail="" c i
  case "$p" in *[$'\n\r']*) return 1 ;; esac
  for ((i = 0; i < ${#p}; i++)); do
    c="${p:i:1}"
    case "$c" in '\'|'*'|'?'|'['|']') out="$out\\$c" ;; *) out="$out$c" ;; esac
  done
  while [ "${out% }" != "$out" ]; do out=${out% }; trail="$trail\\ "; done
  printf '/%s%s' "$out" "$trail"
}

# ---------------------------------------------------------------- refusal block

# Values of a large file refusal, one entry per file of CC_PATHS (sizes in CC_SIZES and limit in CC_MAX_BYTES, bytes).
# Format, read by the tests: a first line, then per file a line starting with "- " and 5 lines starting with two
# spaces; each of them "<label>: <value>", in this order: path, size, limit, .gitattributes pass line, untrack command,
# .gitignore line. A path holding a tab, newline or carriage return is shown shell-quoted (one line per value).
cc_refusal_block() {
  local i path ignore limit
  limit=$(cc_size_mb "${CC_MAX_BYTES:-0}")
  printf 'Large files refused (%d):\n' "${#CC_PATHS[@]}"
  for ((i = 0; i < ${#CC_PATHS[@]}; i++)); do
    path=${CC_PATHS[$i]}
    case "$path" in *[$'\n\r\t']*) path=$(cc_shell_quote "$path") ;; esac
    ignore=$(cc_ignore_line "${CC_PATHS[$i]}") || ignore=$CC_IGNORE_NONE
    printf -- '- path: %s\n' "$path"
    printf '  size (MB): %s\n' "$(cc_size_mb "${CC_SIZES[$i]:-0}")"
    printf '  limit (MB): %s\n' "$limit"
    printf '  .gitattributes pass line: %s\n' "$(cc_pass_line "${CC_PATHS[$i]}")"
    printf '  untrack command: %s\n' "$(cc_untrack_command "${CC_PATHS[$i]}")"
    printf '  .gitignore line: %s\n' "$ignore"
  done
}
