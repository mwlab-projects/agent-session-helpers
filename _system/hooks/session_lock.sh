#!/bin/bash
# "Busy" lock for stop_hook.sh (sourced, never run directly): several sessions open in the same
# repository must not commit/push at the same moment. A directory inside .git (never versioned,
# invisible in the project), removed as soon as the hook exits. `mkdir` is atomic on every OS.

SESSION_LOCK_DIR=""

# session_lock_acquire <repo> <timeout_seconds>
# Returns 0 once the lock is held (released automatically when the script exits), 1 on timeout.
# SESSION_LOCK_TIMEOUT overrides the timeout (used by the test suites).
session_lock_acquire() {
  local repo="$1" timeout="${SESSION_LOCK_TIMEOUT:-$2}" common lock owner tries=0
  common=$(cd "$repo" && cd "$(git rev-parse --git-common-dir)" && pwd) || return 1
  lock="$common/session-hooks.lock"
  while ! mkdir "$lock" 2>/dev/null; do
    # Stale lock left by a run that never released it (crash, harness killed the hook):
    # owner process gone, or lock older than 10 minutes (no legitimate run lasts that long).
    owner=$(cat "$lock/pid" 2>/dev/null)
    if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } || \
       [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rm -rf "$lock"
      continue
    fi
    [ "$tries" -ge $((timeout * 2)) ] && return 1
    sleep 0.5
    tries=$((tries + 1))
  done
  echo "$$" > "$lock/pid"
  SESSION_LOCK_DIR="$lock"
  trap session_lock_release EXIT
  return 0
}

session_lock_release() {
  [ -n "$SESSION_LOCK_DIR" ] && rm -rf "$SESSION_LOCK_DIR"
  SESSION_LOCK_DIR=""
}
