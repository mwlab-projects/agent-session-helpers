#!/bin/bash
# Sync of the repository with its remote (origin/main). Identical in every repository using the session hooks.
# Sourced by stop_hook.sh, session_start_hook.sh and the system-audit commit script. Can also be run directly
# (`bash _system/hooks/scripts/sync_git_with_remote.sh`) to retry a sync by hand.
# Direct run with `--no-files`: no file written in the folder nor .git/info/exclude (no session_error.log, no conflict folder: a true conflict only returns status conflict).
#
# Several agent sessions share one working folder. Guarantees:
#   - uncommitted work is never stashed, reset or lost, and nothing is ever rebased in the folder;
#   - a save reaches the remote even while other sessions have files in progress: the merge with origin/main is
#     computed without touching the folder (`git merge-tree`), then pushed;
#   - the folder then receives the remote changes, file by file:
#       * a file nobody is editing is replaced by the remote version,
#       * a file in progress gets the remote changes by a line-level 3-way merge, written in one block, only if
#         the merge is clean (the session edited other lines) and the file did not change meanwhile,
#       * if a file in progress cannot be merged (same lines changed, binary, deleted on one side...), the folder
#         is left as is (status deferred) and catches up once that file is saved;
#   - same lines changed in two commits (true conflict): nothing is pushed or touched. The files to resolve are
#     written to _system/sync_conflict/ (inside the folder: agents under Codex cannot write .git), an agent
#     resolves them, and the next hook run finalizes (merge commit, push, folder update);
#   - a run killed at any point loses nothing: the next run converges.
# Requires git >= 2.38 (merge-tree --write-tree), enforced at install/update time. Compatible with bash 3.2.
#
# Library use: source this file, take the lock with `hooks_lock_acquire`, then `sync_git_with_remote <repo>`:
#   SYNC_STATUS  ok | deferred | conflict | fetch_failed | push_failed | not_main | error
#   SYNC_FILES   deferred: files in progress blocking the update; conflict: files to resolve (one per line)
#   SYNC_DETAIL  detail for the error log (git output...)
#   SYNC_NEVER_FETCHED  1 when origin/main was never fetched (fetch_failed only)
# `sync_status_block` turns these results into the [sync] block of session_error.log (`sync_log_set`).

SYNC_CONFLICT_REL="_system/sync_conflict"
SYNC_CONFLICT_INSTRUCTIONS="sync_conflict_resolution_instructions.md"
SYNC_CONFLICT_STATE=".sync_conflict_state"
SYNC_MERGE_MESSAGE="Sync: merge origin/main (automatic, session hooks)"
SYNC_RESOLVED_MESSAGE="Sync: merge origin/main (conflict resolved by an agent)"
SYNC_MARKERS='^(<<<<<<<|>>>>>>>)( |$)'
SYNC_NO_FILES=0

# ---------------------------------------------------------------- locks and cleanup

_sync_pid_alive() { kill -0 "$1" 2>/dev/null || ps -p "$1" >/dev/null 2>&1; }

# One hook run at a time across all sessions: every open session fires the hooks, and two runs at the same moment
# used to process the same commit file twice (duplicate commit, false "push failed" alert). The lock is a directory
# in the git common dir (mkdir is atomic on every OS, never versioned, shared by worktrees), removed on exit.
# A stale lock (owner process gone, or older than 10 min) is taken over. Returns 1 if still busy after $2 seconds.
hooks_lock_acquire() {
  local tries=0 owner common
  common=$(cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd) || return 1
  HOOKS_LOCK="$common/session-hooks.lock"
  until mkdir "$HOOKS_LOCK" 2>/dev/null; do
    owner=$(cat "$HOOKS_LOCK/pid" 2>/dev/null)
    if { [ -n "$owner" ] && ! _sync_pid_alive "$owner"; } || \
       [ -n "$(find "$HOOKS_LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rm -rf "$HOOKS_LOCK"
      continue
    fi
    [ "$tries" -ge $(( $2 * 2 )) ] && { HOOKS_LOCK=""; return 1; }
    sleep 0.5
    tries=$((tries + 1))
  done
  echo "$$" > "$HOOKS_LOCK/pid"
  trap '_sync_on_exit' EXIT
  trap '_sync_on_exit; exit 130' INT TERM HUP
  return 0
}

hooks_lock_release() {
  [ -n "${HOOKS_LOCK:-}" ] && rm -rf "$HOOKS_LOCK"
  HOOKS_LOCK=""
}

_sync_on_exit() {
  [ "${SYNC_INDEX_LOCK_OWNED:-0}" = 1 ] && rm -f "$SYNC_INDEX_LOCK"
  SYNC_INDEX_LOCK_OWNED=0
  [ -n "${SYNC_TMP:-}" ] && rm -rf "$SYNC_TMP"
  hooks_lock_release
}

# Git's own index lock, taken while the folder is updated so that no other git command changes the index meanwhile.
# Marked with our pid: a lock left by a killed run is recognised and removed.
_sync_index_lock() {
  local i=0 pid
  while ! ( set -o noclobber; printf 'hub-sync %s\n' "$$" > "$SYNC_INDEX_LOCK" ) 2>/dev/null; do
    pid=$(sed -n 's/^hub-sync //p' "$SYNC_INDEX_LOCK" 2>/dev/null)
    if [ -n "$pid" ] && ! _sync_pid_alive "$pid"; then
      rm -f "$SYNC_INDEX_LOCK"
      continue
    fi
    i=$((i + 1))
    [ "$i" -ge 40 ] && return 1
    sleep 0.25
  done
  SYNC_INDEX_LOCK_OWNED=1
  return 0
}

_sync_index_unlock() {
  [ "${SYNC_INDEX_LOCK_OWNED:-0}" = 1 ] && rm -f "$SYNC_INDEX_LOCK"
  SYNC_INDEX_LOCK_OWNED=0
}

# Runs git, retrying for ~10 s while another git command (VS Code, an agent) holds the index lock.
# Prints git's combined output, returns its exit code.
git_retry_index_lock() {
  local i=0 out rc
  while :; do
    out=$(git "$@" 2>&1)
    rc=$?
    if [ "$rc" -ne 0 ] && [ "$i" -lt 40 ]; then
      case "$out" in *index.lock*) i=$((i + 1)); sleep 0.25; continue ;; esac
    fi
    [ -n "$out" ] && printf '%s\n' "$out"
    return "$rc"
  done
}

# ---------------------------------------------------------------- helpers

_sync_git() { git -C "$SYNC_REPO" "$@"; }

_sync_anc() { _sync_git merge-base --is-ancestor "$1" "$2" 2>/dev/null; }

# Test seam: runs $SYNC_TEST_HOOK (an executable) at named points, to simulate concurrent writes and crashes.
_sync_test_hook() {
  [ -n "${SYNC_TEST_HOOK:-}" ] && "$SYNC_TEST_HOOK" "$@"
  return 0
}

_sync_paths() {
  local p
  p=$(_sync_git rev-parse --git-path index 2>/dev/null) || return 1
  case "$p" in /*|[A-Za-z]:*) ;; *) p="$SYNC_REPO/$p" ;; esac
  SYNC_INDEX="$p"
  SYNC_INDEX_LOCK="$p.lock"
  SYNC_GITDIR=$(cd "$(dirname -- "$p")" && pwd) || return 1
  SYNC_TMP="$SYNC_GITDIR/hub-sync-tmp"
  SYNC_CONFLICT_DIR="$SYNC_REPO/$SYNC_CONFLICT_REL"
}

_sync_fetch() {
  local i=0 out
  while :; do
    i=$((i + 1))
    out=$(_sync_git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 fetch origin main 2>&1) && return 0
    # VS Code or the cockpit fetching at the same moment: retry; anything else (offline...) fails at once
    case "$out" in *lock*) [ "$i" -lt 5 ] && { sleep 1; continue; } ;; esac
    SYNC_DETAIL="$out"
    return 1
  done
}

# 0 pushed; 1 rejected (the remote moved: fetch and merge again); 2 other failure. SYNC_DETAIL = git output.
_sync_push() {
  local i=0 out
  while :; do
    i=$((i + 1))
    out=$(_sync_git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 push origin "$1:refs/heads/main" 2>&1) && return 0
    SYNC_DETAIL="$out"
    case "$out" in
      *rejected*) return 1 ;;
      *lock*) [ "$i" -lt 5 ] && { sleep 1; continue; } ;;
    esac
    return 2
  done
}

# Merges $1 (local side) and $2 (remote side) without touching the folder.
# 0: SYNC_TARGET = merge commit; 1: conflict (SYNC_MT_TREE + $SYNC_TMP/merge-tree); 2: git error.
_sync_merge() {
  local rc tree
  mkdir -p "$SYNC_TMP"
  _sync_git merge-tree --write-tree -z "$1" "$2" > "$SYNC_TMP/merge-tree" 2> "$SYNC_TMP/merge-tree.err"
  rc=$?
  IFS= read -r -d '' tree < "$SYNC_TMP/merge-tree"
  case "$rc" in
    0)
      SYNC_TARGET=$(_sync_git commit-tree "$tree" -p "$1" -p "$2" -m "$SYNC_MERGE_MESSAGE" 2>&1) && return 0
      SYNC_DETAIL="$SYNC_TARGET"
      return 2 ;;
    1)
      SYNC_MT_TREE="$tree"
      return 1 ;;
    *)
      SYNC_DETAIL=$(cat "$SYNC_TMP/merge-tree.err"; tr '\0' '\n' < "$SYNC_TMP/merge-tree")
      return 2 ;;
  esac
}

# Files that differ from commit $1 in the folder (modified or deleted), newline-framed for exact matching
_sync_dirty_set() {
  GIT_OPTIONAL_LOCKS=0 git -C "$SYNC_REPO" diff --name-only -z --no-renames "$1" -- | tr '\0' '\n'
}

_sync_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# An untracked file (or link) already sits where the remote adds $1 (mode $2, blob $3, commit $4): same content?
_sync_same_content() {
  local f="$SYNC_REPO/$1"
  if [ "$2" = 120000 ]; then
    [ -L "$f" ] && [ "$(readlink "$f")" = "$(_sync_git cat-file -p "$3")" ] && return 0
    # without symlink support (Windows), git writes a link as a plain file holding its target
    [ ! -L "$f" ] && [ -f "$f" ] && [ "$(cat "$f")" = "$(_sync_git cat-file -p "$3")" ] && return 0
    return 1
  fi
  [ -f "$f" ] && [ ! -L "$f" ] && _sync_git cat-file --filters "$4:$1" | cmp -s - "$f"
}

# ---------------------------------------------------------------- folder update

# Brings the folder from $1 (HEAD) to $2, touching only the files the remote changed (see header).
_sync_update_folder() {
  local head="$1" target="$2" attempt=0 retry out ic dirty now deletes_lc blocking n meta p src dst soid doid st
  local local_exists in_progress lc mode d
  [ "$head" = "$target" ] && return 0
  if ! _sync_index_lock; then
    SYNC_STATUS=deferred
    SYNC_DETAIL="Another git command keeps holding $SYNC_INDEX_LOCK."
    return 0
  fi
  ic=$(_sync_git config --bool core.ignorecase 2>/dev/null)
  while :; do
    attempt=$((attempt + 1))
    retry=0
    rm -rf "$SYNC_TMP"
    mkdir -p "$SYNC_TMP/m"
    [ -f "$SYNC_INDEX" ] && cp "$SYNC_INDEX" "$SYNC_TMP/index"
    # New index = target, keeping what sessions staged elsewhere (e.g. a rename in progress). Refused when
    # something staged touches a file the remote changed: nothing is touched then. -i: the folder itself is
    # checked below, file by file (files in progress are merged, not refused).
    if ! out=$(GIT_INDEX_FILE="$SYNC_TMP/index" git -C "$SYNC_REPO" read-tree -m -i "$head" "$target" 2>&1); then
      SYNC_STATUS=deferred
      SYNC_DETAIL="$out"
      SYNC_FILES=$(printf '%s\n' "$out" | sed -n "s/^error: Entry '\(.*\)' .*/\1/p")
      break
    fi
    _sync_git diff --raw -z --no-renames --no-abbrev "$head" "$target" > "$SYNC_TMP/raw"
    dirty=$'\n'"$(_sync_dirty_set "$head")"$'\n'

    # Case-insensitive file system: a remote case-only rename (foo.md -> Foo.md) finds "Foo.md" already on disk
    deletes_lc=$'\n'
    if [ "$ic" = true ]; then
      while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
        read -r src dst soid doid st <<< "${meta#:}"
        [ "$dst" = 000000 ] || continue
        case "$dirty" in *$'\n'"$p"$'\n'*) continue ;; esac
        deletes_lc="$deletes_lc$(_sync_lower "$p")"$'\n'
      done < "$SYNC_TMP/raw"
    fi

    blocking=""
    n=0
    : > "$SYNC_TMP/updates"
    : > "$SYNC_TMP/adds"
    : > "$SYNC_TMP/deletes"
    : > "$SYNC_TMP/merges"
    while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
      read -r src dst soid doid st <<< "${meta#:}"
      local_exists=0
      { [ -e "$SYNC_REPO/$p" ] || [ -L "$SYNC_REPO/$p" ]; } && local_exists=1
      in_progress=0
      case "$dirty" in *$'\n'"$p"$'\n'*) in_progress=1 ;; esac

      if [ "$src" = 000000 ] && [ "$local_exists" = 1 ]; then
        if [ "$ic" = true ]; then
          lc=$(_sync_lower "$p")
          case "$deletes_lc" in *$'\n'"$lc"$'\n'*) printf '%s\0' "$p" >> "$SYNC_TMP/updates"; continue ;; esac
        fi
        _sync_same_content "$p" "$dst" "$doid" "$target" && continue
        blocking="$blocking$p"$'\n'
        continue
      fi

      if [ "$in_progress" = 0 ]; then
        if [ "$dst" = 000000 ]; then
          printf '%s\0' "$p" >> "$SYNC_TMP/deletes"
        else
          printf '%s\0' "$p" >> "$SYNC_TMP/updates"
          [ "$src" = 000000 ] && printf '%s\0' "$p" >> "$SYNC_TMP/adds"
        fi
        continue
      fi

      # In progress here: line-level merge, only in the plain case (regular text file on both sides)
      if [ "$src" = 000000 ] || [ "$dst" = 000000 ] || [ "$local_exists" = 0 ] || [ -L "$SYNC_REPO/$p" ] || \
         [ "$src" != "$dst" ] || { [ "$src" != 100644 ] && [ "$src" != 100755 ]; }; then
        blocking="$blocking$p"$'\n'
        continue
      fi
      n=$((n + 1))
      if cp "$SYNC_REPO/$p" "$SYNC_TMP/m/$n.ours" && \
         _sync_git cat-file --filters "$head:$p" > "$SYNC_TMP/m/$n.base" && \
         _sync_git cat-file --filters "$target:$p" > "$SYNC_TMP/m/$n.theirs" && \
         git merge-file -p "$SYNC_TMP/m/$n.ours" "$SYNC_TMP/m/$n.base" "$SYNC_TMP/m/$n.theirs" \
           > "$SYNC_TMP/m/$n.merged" 2>/dev/null; then
        printf '%s\0%s\0%s\0' "$p" "$dst" "$n" >> "$SYNC_TMP/merges"
      else
        blocking="$blocking$p"$'\n'
      fi
    done < "$SYNC_TMP/raw"

    if [ -n "$blocking" ]; then
      SYNC_STATUS=deferred
      SYNC_FILES="$blocking"
      SYNC_DETAIL="Files in progress here cannot take the remote changes yet (same lines changed, binary, deleted or added on one side): the folder catches up once they are saved."
      break
    fi

    # 1. Files in progress: write the merged version in one block, only if the file did not change since read
    while IFS= read -r -d '' p && IFS= read -r -d '' mode && IFS= read -r -d '' n; do
      _sync_test_hook before-replace "$p"
      if ! cmp -s "$SYNC_TMP/m/$n.ours" "$SYNC_REPO/$p"; then retry=1; break; fi
      [ "$mode" = 100755 ] && chmod +x "$SYNC_TMP/m/$n.merged"
      mv -f "$SYNC_TMP/m/$n.merged" "$SYNC_REPO/$p" || { retry=1; break; }
    done < "$SYNC_TMP/merges"

    # 2. Files nobody edits: check they are still untouched right before replacing or deleting them
    if [ "$retry" = 0 ]; then
      _sync_test_hook before-checkout
      now=$'\n'"$(_sync_dirty_set "$head")"$'\n'
      while IFS= read -r -d '' p; do
        case "$now" in *$'\n'"$p"$'\n'*) retry=1; break ;; esac
      done < <(cat "$SYNC_TMP/updates" "$SYNC_TMP/deletes")
      while [ "$retry" = 0 ] && IFS= read -r -d '' p; do
        { [ -e "$SYNC_REPO/$p" ] || [ -L "$SYNC_REPO/$p" ]; } && retry=1
      done < "$SYNC_TMP/adds"
    fi
    if [ "$retry" = 1 ]; then
      [ "$attempt" -lt 3 ] && continue
      SYNC_STATUS=deferred
      SYNC_DETAIL="Files kept changing during the update: retried at the next sync."
      break
    fi
    while IFS= read -r -d '' p; do
      rm -f "$SYNC_REPO/$p"
      d=$(dirname -- "$p")
      while [ "$d" != . ] && rmdir "$SYNC_REPO/$d" 2>/dev/null; do d=$(dirname -- "$d"); done
    done < "$SYNC_TMP/deletes"
    if [ -s "$SYNC_TMP/updates" ] && \
       ! out=$(GIT_INDEX_FILE="$SYNC_TMP/index" git -C "$SYNC_REPO" checkout-index -f -u -z --stdin < "$SYNC_TMP/updates" 2>&1); then
      SYNC_STATUS=error
      SYNC_DETAIL="checkout-index failed: $out"
      break
    fi

    # 3. Publish: index first (a crash right after only leaves the remote changes staged, which any later
    # commit would merely repeat), then the branch.
    _sync_test_hook before-publish
    if ! mv -f "$SYNC_TMP/index" "$SYNC_INDEX"; then
      SYNC_STATUS=error
      SYNC_DETAIL="Could not replace $SYNC_INDEX."
      break
    fi
    if ! out=$(_sync_git update-ref -m "sync: fast-forward to origin/main (session hooks)" refs/heads/main "$target" "$head" 2>&1); then
      SYNC_STATUS=error
      SYNC_DETAIL="update-ref failed: $out"
    fi
    break
  done
  _sync_index_unlock
  rm -rf "$SYNC_TMP"
}

# ---------------------------------------------------------------- true conflicts

_sync_exclude_conflict_dir() {
  local ex
  ex=$(_sync_git rev-parse --git-path info/exclude) || return 0
  case "$ex" in /*|[A-Za-z]:*) ;; *) ex="$SYNC_REPO/$ex" ;; esac
  mkdir -p "$(dirname -- "$ex")"
  grep -qxF "/$SYNC_CONFLICT_REL/" "$ex" 2>/dev/null || printf '/%s/\n' "$SYNC_CONFLICT_REL" >> "$ex"
}

_sync_is_text_pair() {
  case "$(_sync_git diff --numstat "$1" "$2" 2>/dev/null)" in -*) return 1 ;; esac
  return 0
}

# One conflicted path: $1 path, $2/$3 local mode/blob, $4/$5 remote mode/blob ("-" when absent on that side)
_sync_conflict_entry() {
  local p="$1" f="$SYNC_CONFLICT_DIR/$1" why
  mkdir -p "$(dirname -- "$f")"
  if [ "$2" != - ] && [ "$4" != - ] && { [ "$2" = 100644 ] || [ "$2" = 100755 ]; } && \
     { [ "$4" = 100644 ] || [ "$4" = 100755 ]; } && _sync_is_text_pair "$3" "$5"; then
    _sync_git cat-file --filters "$SYNC_MT_TREE:$p" > "$f"
    printf 'text\t%s\n' "$p" >> "$SYNC_CONFLICT_DIR/$SYNC_CONFLICT_STATE.tmp"
    SYNC_CONFLICT_LIST="$SYNC_CONFLICT_LIST- \`$p\` : modifié des deux côtés"$'\n'
    SYNC_FILES="$SYNC_FILES$p"$'\n'
    return 0
  fi
  if [ "$2" = - ]; then why="supprimé ici, modifié sur le dépôt distant"
  elif [ "$4" = - ]; then why="modifié ici, supprimé sur le dépôt distant"
  else why="modifié des deux côtés, impossible à fusionner ligne à ligne (binaire, lien ou type différent)"; fi
  [ "$2" != - ] && _sync_git cat-file --filters --path="$p" "$3" > "$f.local_version"
  [ "$4" != - ] && _sync_git cat-file --filters --path="$p" "$5" > "$f.remote_version"
  printf '<<<<<<< CHOIX À FAIRE pour « %s » : %s.\nRemplace tout le contenu de ce fichier par un seul mot : KEEP_LOCAL, KEEP_REMOTE ou DELETE.\n>>>>>>> CHOIX À FAIRE\n' \
    "$p" "$why" > "$f.choice"
  printf 'choice\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$p" >> "$SYNC_CONFLICT_DIR/$SYNC_CONFLICT_STATE.tmp"
  SYNC_CONFLICT_LIST="$SYNC_CONFLICT_LIST- \`$p.choice\` : $why"$'\n'
  SYNC_FILES="$SYNC_FILES$p.choice"$'\n'
}

# Writes the files to resolve for the merge of $1 (local side) and $2 (remote side). Never overwrites a resolution
# already in progress.
_sync_conflict_prepare() {
  local d="$SYNC_CONFLICT_DIR" tok cur="" m2=- o2=- m3=- o3=- mode oid stage p
  [ -f "$d/$SYNC_CONFLICT_STATE" ] && return 0
  _sync_exclude_conflict_dir
  rm -rf "$d"
  mkdir -p "$d"
  # The state file is published last: a run killed midway leaves no half-listed conflict (whose files would
  # keep their markers)
  printf 'local %s\nremote %s\ntree %s\n' "$1" "$2" "$SYNC_MT_TREE" > "$d/$SYNC_CONFLICT_STATE.tmp"
  SYNC_CONFLICT_LIST=""
  SYNC_FILES=""
  # merge-tree -z: tree, then "<mode> <blob> <stage>\t<path>" records grouped by path, ended by an empty record
  {
    IFS= read -r -d '' tok
    while IFS= read -r -d '' tok && [ -n "$tok" ]; do
      p="${tok#*	}"
      read -r mode oid stage <<< "${tok%%	*}"
      if [ "$p" != "$cur" ]; then
        [ -n "$cur" ] && _sync_conflict_entry "$cur" "$m2" "$o2" "$m3" "$o3"
        cur="$p"; m2=-; o2=-; m3=-; o3=-
      fi
      case "$stage" in 2) m2="$mode"; o2="$oid" ;; 3) m3="$mode"; o3="$oid" ;; esac
    done
    [ -n "$cur" ] && _sync_conflict_entry "$cur" "$m2" "$o2" "$m3" "$o3"
  } < "$SYNC_TMP/merge-tree"
  {
    printf '# Conflit de synchronisation à résoudre\n\n'
    printf 'Les mêmes lignes ont été modifiées sur cette machine (côté `HEAD`) et sur le dépôt distant (côté `origin/main`).\n'
    printf 'Rien n'"'"'est perdu : les deux versions sont ici. Aucune sauvegarde ne part tant que ce n'"'"'est pas résolu.\n\n'
    printf '1. Fichiers « modifié des deux côtés » : dans chaque bloc de conflit, la partie entre `<<<<<<<` et `=======` est la version de cette machine, celle entre `=======` et `>>>>>>>` la version du dépôt distant. Fusionne-les en gardant l'"'"'intention de chacune, puis retire ces trois lignes de marqueurs.\n'
    printf '2. Fichiers `.choice` : remplace tout leur contenu par un seul mot : `KEEP_LOCAL` (garder la version de cette machine), `KEEP_REMOTE` (garder celle du dépôt distant) ou `DELETE` (supprimer le fichier). Les fichiers `.local_version` et `.remote_version` montrent les deux versions.\n'
    printf '3. Si les deux versions se contredisent vraiment, demande à l'"'"'utilisateur.\n\n'
    printf 'Ne modifie que les fichiers de ce dossier, jamais leurs équivalents dans le dossier de travail ni `.sync_conflict_state`. La suite (sauvegarde, envoi, mise à jour du dossier de travail) est automatique à la fin de ton tour.\n\n'
    printf '## Fichiers\n\n'
    printf '%s' "$SYNC_CONFLICT_LIST"
  } > "$d/$SYNC_CONFLICT_INSTRUCTIONS"
  mv -f "$d/$SYNC_CONFLICT_STATE.tmp" "$d/$SYNC_CONFLICT_STATE"
}

# Returns 0 when no conflict is pending (or once its resolution is pushed), 1 while one is still open.
_sync_conflict_finalize() {
  local d="$SYNC_CONFLICT_DIR" L O T R kind m2 o2 m3 o3 p word unresolved="" oid mode zero tree candidate origin rc
  local attempt=0
  [ -f "$d/$SYNC_CONFLICT_STATE" ] || return 0
  L=$(sed -n 's/^local //p' "$d/$SYNC_CONFLICT_STATE")
  O=$(sed -n 's/^remote //p' "$d/$SYNC_CONFLICT_STATE")
  T=$(sed -n 's/^tree //p' "$d/$SYNC_CONFLICT_STATE")
  R=$(sed -n 's/^resolved //p' "$d/$SYNC_CONFLICT_STATE")
  if [ -z "$R" ]; then
    while IFS="$(printf '\t')" read -r kind m2 o2 m3 o3 p; do
      case "$kind" in
        text)
          p="$m2"
          if [ ! -f "$d/$p" ] || grep -qE "$SYNC_MARKERS" "$d/$p"; then unresolved="$unresolved$p"$'\n'; fi ;;
        choice)
          word=$(tr -d ' \t\r\n' < "$d/$p.choice" 2>/dev/null)
          case "$word" in KEEP_LOCAL|KEEP_REMOTE|DELETE) ;; *) unresolved="$unresolved$p.choice"$'\n' ;; esac ;;
      esac
    done < "$d/$SYNC_CONFLICT_STATE"
    if [ -n "$unresolved" ]; then
      SYNC_STATUS=conflict
      SYNC_FILES="$unresolved"
      SYNC_DETAIL="Resolution in progress in $SYNC_CONFLICT_REL/ (see $SYNC_CONFLICT_INSTRUCTIONS)."
      return 1
    fi
    # Resolution tree: the conflicted merge, with each resolved file or choice applied
    rm -rf "$SYNC_TMP"
    mkdir -p "$SYNC_TMP"
    zero=$(printf "%0${#T}d" 0)
    : > "$SYNC_TMP/index-info"
    while IFS="$(printf '\t')" read -r kind m2 o2 m3 o3 p; do
      case "$kind" in
        text)
          p="$m2"
          oid=$(_sync_git hash-object -w --path="$p" --stdin < "$d/$p") || return 1
          mode=$(_sync_git ls-tree "$T" -- "$p" | awk '{print $1}')
          printf '%s %s\t%s\n' "${mode:-100644}" "$oid" "$p" >> "$SYNC_TMP/index-info" ;;
        choice)
          word=$(tr -d ' \t\r\n' < "$d/$p.choice")
          case "$word" in
            KEEP_LOCAL) [ "$m2" != - ] && printf '%s %s\t%s\n' "$m2" "$o2" "$p" || printf '0 %s\t%s\n' "$zero" "$p" ;;
            KEEP_REMOTE) [ "$m3" != - ] && printf '%s %s\t%s\n' "$m3" "$o3" "$p" || printf '0 %s\t%s\n' "$zero" "$p" ;;
            DELETE) printf '0 %s\t%s\n' "$zero" "$p" ;;
          esac >> "$SYNC_TMP/index-info" ;;
      esac
    done < "$d/$SYNC_CONFLICT_STATE"
    GIT_INDEX_FILE="$SYNC_TMP/resolution-index" git -C "$SYNC_REPO" read-tree "$T" && \
      GIT_INDEX_FILE="$SYNC_TMP/resolution-index" git -C "$SYNC_REPO" update-index --index-info < "$SYNC_TMP/index-info" && \
      tree=$(GIT_INDEX_FILE="$SYNC_TMP/resolution-index" git -C "$SYNC_REPO" write-tree) && \
      R=$(_sync_git commit-tree "$tree" -p "$L" -p "$O" -m "$SYNC_RESOLVED_MESSAGE") || {
        SYNC_STATUS=error
        SYNC_DETAIL="Could not build the resolution commit from $SYNC_CONFLICT_REL/."
        return 1
      }
    printf 'resolved %s\n' "$R" >> "$d/$SYNC_CONFLICT_STATE"
  fi

  # Push the resolution (merged again if the remote moved meanwhile)
  candidate="$R"
  while :; do
    attempt=$((attempt + 1))
    origin=$(_sync_git rev-parse origin/main)
    if _sync_anc "$candidate" "$origin"; then
      break
    elif _sync_anc "$origin" "$candidate"; then
      _sync_push "$candidate"
      rc=$?
      [ "$rc" = 0 ] && break
      if [ "$rc" = 1 ] && [ "$attempt" -lt 4 ] && _sync_fetch; then continue; fi
      SYNC_STATUS=push_failed
      return 1
    else
      _sync_merge "$candidate" "$origin"
      rc=$?
      if [ "$rc" = 1 ]; then
        # The remote changed the same lines again: new round on top of the resolution
        rm -rf "$d"
        _sync_conflict_prepare "$candidate" "$origin"
        SYNC_STATUS=conflict
        return 1
      fi
      [ "$rc" = 0 ] || { SYNC_STATUS=error; return 1; }
      candidate="$SYNC_TARGET"
    fi
  done
  rm -rf "$d"
  return 0
}

# ---------------------------------------------------------------- main entry point

sync_git_with_remote() {
  local head origin target rc attempt=0 pid
  SYNC_REPO="$1"
  SYNC_STATUS=ok
  SYNC_DETAIL=""
  SYNC_FILES=""
  SYNC_NEVER_FETCHED=0
  SYNC_TARGET=""
  unset GIT_INDEX_FILE
  export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
  if ! _sync_paths; then
    SYNC_STATUS=error
    SYNC_DETAIL="Not a git repository: $SYNC_REPO"
    return 0
  fi
  trap '_sync_on_exit' EXIT
  trap '_sync_on_exit; exit 130' INT TERM HUP

  # Leftovers of a run killed midway: our own index lock and temporary files
  pid=$(sed -n 's/^hub-sync //p' "$SYNC_INDEX_LOCK" 2>/dev/null)
  [ -n "$pid" ] && ! _sync_pid_alive "$pid" && rm -f "$SYNC_INDEX_LOCK"
  rm -rf "$SYNC_TMP"

  if [ "$(_sync_git symbolic-ref -q HEAD)" != refs/heads/main ]; then
    SYNC_STATUS=not_main
    SYNC_DETAIL=$(_sync_git symbolic-ref -q --short HEAD || echo "detached HEAD")
    return 0
  fi
  if ! _sync_fetch; then
    SYNC_STATUS=fetch_failed
    _sync_git rev-parse -q --verify refs/remotes/origin/main >/dev/null || SYNC_NEVER_FETCHED=1
    return 0
  fi
  if [ "$SYNC_NO_FILES" = 0 ]; then _sync_conflict_finalize || return 0; fi

  while :; do
    attempt=$((attempt + 1))
    head=$(_sync_git rev-parse HEAD)
    origin=$(_sync_git rev-parse origin/main)
    if _sync_anc "$origin" "$head"; then
      target="$head"
    elif _sync_anc "$head" "$origin"; then
      target="$origin"
    else
      _sync_merge "$head" "$origin"
      rc=$?
      if [ "$rc" = 1 ]; then
        [ "$SYNC_NO_FILES" = 1 ] || _sync_conflict_prepare "$head" "$origin"
        SYNC_STATUS=conflict
        return 0
      fi
      [ "$rc" = 0 ] || { SYNC_STATUS=error; return 0; }
      target="$SYNC_TARGET"
    fi
    if ! _sync_anc "$target" "$origin"; then
      _sync_push "$target"
      rc=$?
      if [ "$rc" = 1 ] && [ "$attempt" -lt 4 ] && _sync_fetch; then continue; fi
      [ "$rc" = 0 ] || { SYNC_STATUS=push_failed; return 0; }
    fi
    break
  done
  _sync_update_folder "$head" "$target"
  return 0
}

# ---------------------------------------------------------------- session_error.log

# session_error.log holds blank-line separated blocks. A block tagged "[sync]" (or "[stash]") always describes the
# current state: each call replaces the previous block of that tag ("" removes it). Other blocks (e.g. a failed
# git add) stay until an agent has handled them.
sync_log_set() {
  local log="$1/session_error.log" tmp gd
  gd=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  tmp="$gd/session_error.log.tmp"
  {
    [ -f "$log" ] && awk -v tag="[$2]" 'BEGIN { RS = ""; ORS = "\n\n" } index($0, tag) != 1' "$log"
    [ -n "$3" ] && printf '[%s] %s\n\n' "$2" "$(printf '%s\n' "$3" | sed '/^[[:space:]]*$/d')"
  } > "$tmp"
  if [ -s "$tmp" ]; then mv -f "$tmp" "$log"; else rm -f "$tmp" "$log"; fi
}

# The [sync] block for the current results ("" when there is nothing to report)
sync_status_block() {
  local ahead
  case "$SYNC_STATUS" in
    conflict)
      printf 'Sync conflict: the same lines were changed here and on the remote. Nothing pushed, no file touched, local commits kept. Files to resolve in %s/ (instructions: %s/%s):\n%s' \
        "$SYNC_CONFLICT_REL" "$SYNC_CONFLICT_REL" "$SYNC_CONFLICT_INSTRUCTIONS" "$SYNC_FILES" ;;
    push_failed)
      printf 'Push failed: local commits kept, not pushed. git output:\n%s' "$SYNC_DETAIL" ;;
    fetch_failed)
      if [ "$SYNC_NEVER_FETCHED" = 1 ]; then
        printf 'Remote unreachable and never synced: check the origin remote. git output:\n%s' "$SYNC_DETAIL"
      else
        ahead=$(git -C "$SYNC_REPO" rev-list --count origin/main..HEAD 2>/dev/null)
        [ "${ahead:-0}" -gt 0 ] && \
          printf 'Remote unreachable: %s local commit(s) not pushed yet, kept and pushed at the next sync. git output:\n%s' "$ahead" "$SYNC_DETAIL"
      fi ;;
    not_main)
      printf "Sync disabled: the current branch is '%s', not main. Saves stay local. Tell the user; never switch branches yourself." "$SYNC_DETAIL" ;;
    error)
      printf 'Sync error, local commits kept: %s' "$SYNC_DETAIL" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- direct run

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ "${1:-}" = --no-files ] && SYNC_NO_FILES=1
  REPO=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "Not inside a git repository."; exit 1; }
  git -C "$REPO" remote get-url origin >/dev/null 2>&1 || { echo "No origin remote: nothing to sync."; exit 0; }
  hooks_lock_acquire "$REPO" 60 || { echo "Another session is syncing: try again in a minute."; exit 1; }
  sync_git_with_remote "$REPO"
  [ "$SYNC_NO_FILES" = 1 ] || sync_log_set "$REPO" sync "$(sync_status_block)"
  echo "Sync status: $SYNC_STATUS"
  [ -n "$SYNC_FILES" ] && printf 'Files:\n%s\n' "$SYNC_FILES"
  [ -n "$SYNC_DETAIL" ] && printf 'Detail:\n%s\n' "$SYNC_DETAIL"
  case "$SYNC_STATUS" in ok|deferred) exit 0 ;; *) exit 1 ;; esac
fi
