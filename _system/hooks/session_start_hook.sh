#!/bin/bash
# SessionStart hook: runs automatically at the beginning of each new agent session.
# Syncs the repository with its remote (see sync_git_with_remote.sh), then injects the context: errors to handle,
# pending sync, context file.

REPO=$(git rev-parse --show-toplevel 2>/dev/null)

# Skip if not in a git repo
[ -n "$REPO" ] || exit 0

ERROR_LOG="$REPO/session_error.log"
SYNC_LIB="$REPO/_system/hooks/scripts/sync_git_with_remote.sh"

# ── Configure which file to inject as context ──────────────────────────────
# Default: CHANGELOG.md. Change to README.md or any other file if preferred.
CONTEXT_FILE="$REPO/CHANGELOG.md"
# ──────────────────────────────────────────────────────────────────────────

# No remote configured (ex. RGPD-conscious local-only repo, no DPA with the git host):
# nothing to sync, skip the whole sync block silently.
SYNC_STATUS=""
if git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
  if [ ! -f "$SYNC_LIB" ]; then
    grep -qF "$SYNC_LIB" "$ERROR_LOG" 2>/dev/null || \
      printf "Missing %s: the repository cannot sync until it is restored.\n\n" "$SYNC_LIB" >> "$ERROR_LOG"
  else
    . "$SYNC_LIB"
    # Same lock as the Stop hook. Busy beyond the timeout: another session is syncing right now, skip.
    if hooks_lock_acquire "$REPO" "${SESSION_START_LOCK_TIMEOUT:-20}"; then
      # Integrates origin/main, pushes pending local commits (e.g. a save whose push failed) and updates the
      # folder without touching other sessions' work. The [sync] block of session_error.log reflects the result.
      sync_git_with_remote "$REPO"
      sync_log_set "$REPO" sync "$(sync_status_block)"
      # A stash is work set aside and never merged back: reported at every session until merged and dropped
      STASHES=$(git -C "$REPO" stash list)
      sync_log_set "$REPO" stash "${STASHES:+Unresolved stash, never merged back:
$STASHES}"
      hooks_lock_release
    fi
  fi
fi

# If session_error.log exists, inject it with instructions: placed before the context below, because hook
# stdout is capped at 10,000 chars (truncated beyond that) and this alert must never be the part that gets cut off.
if [ -f "$ERROR_LOG" ]; then
  echo "=== SESSION_ERROR.LOG START ==="
  echo "⚠️ ERREUR DE SYNCHRONISATION DU DÉPÔT - contenu de session_error.log :"
  cat "$ERROR_LOG"
  echo "Instructions : commence par « Une erreur de synchronisation du dépôt a été détectée. Je corrige. ». D'autres sessions peuvent avoir du travail en cours dans ce dossier : n'exécute jamais git stash, git reset --hard, git rebase, git pull, git merge ni git checkout -- <fichier> ici."
  echo "- Bloc [sync] « Sync conflict » : résous les fichiers listés en suivant _system/sync_conflict/sync_conflict_resolution_instructions.md (tu ne modifies que ce dossier). La suite est automatique à la fin de ton tour."
  echo "- Autres blocs [sync] : ils se mettent à jour seuls à chaque synchro, ne les supprime pas. Corrige la cause si elle est claire et à ta portée (ex. remote mal configuré), puis relance la synchro avec bash _system/hooks/scripts/sync_git_with_remote.sh (sous Codex, elle repart seule à la prochaine sauvegarde) ; sinon informe l'utilisateur en une phrase."
  echo "- Bloc [stash] : git stash show -p, fusionne ce contenu à la main dans les fichiers actuels (sans jamais choisir un côté en silence), sauvegarde, puis git stash drop."
  echo "- Autres blocs (ex. « git add failed ») : traite-les, puis retire-les de session_error.log (supprime le fichier s'il ne contient plus rien)."
  echo "Ne demande jamais à l'utilisateur de lancer des commandes git ; dis-lui en une phrase ce qui a été corrigé."
  echo "=== SESSION_ERROR.LOG END ==="
  echo ""
fi

# Remote changes the folder could not take yet (files in progress here that cannot receive them): agents must
# know before relying on these files. Not an error, nothing for the user to do.
if [ "$SYNC_STATUS" = deferred ]; then
  echo "=== SYNCHRO EN ATTENTE START ==="
  echo "Les dernières modifications du dépôt distant (origin/main) ne sont pas encore dans ce dossier."
  if [ -n "$SYNC_FILES" ]; then
    echo "Ces fichiers en cours ici ne peuvent pas encore les recevoir (mêmes lignes modifiées, binaire, ajout ou suppression d'un seul côté) :"
    printf '%s\n' "$SYNC_FILES" | sed '/^$/d' | head -20 | sed 's/^/- /'
  else
    printf '%s\n' "$SYNC_DETAIL" | head -5
  fi
  echo "Avant de t'appuyer sur un fichier modifié à distance, consulte aussi sa version distante (git show origin/main:<fichier>). Ne force rien (ni stash, ni reset, ni pull) : le dossier se met à jour seul une fois ces fichiers sauvegardés. Inutile d'en parler à l'utilisateur."
  case "$SYNC_DETAIL" in
    *index.lock*) echo "Un fichier .git/index.lock bloque la mise à jour : si aucune commande git ne tourne, supprime-le." ;;
  esac
  echo "=== SYNCHRO EN ATTENTE END ==="
  echo ""
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

exit 0
