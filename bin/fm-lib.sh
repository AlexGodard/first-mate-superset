#!/usr/bin/env bash
# Shared helpers for the first-mate scripts. Source it:
#   . "$(dirname "$0")/fm-lib.sh"
#
# Today it carries a portable mkdir-based SINGLETON LOCK (ported from upstream
# firstmate's fm-wake-lib.sh, kunchenguid/firstmate#29). Used by the watcher so a
# second `/first-mate watch` can't double-arm a background watcher (two watchers =
# two wake turns per fleet change). `mkdir` is atomic on every POSIX fs, so it is a
# safe cross-process lock without flock (absent/inconsistent on macOS).
#
# A lock is a directory holding a `pid` file. Acquire = mkdir wins the race + we
# stamp our pid. A lock whose pid is dead (or unreadable + older than the stale
# window) is reclaimed, so a crashed holder never wedges the lock forever.

FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-3}"   # seconds before a pidless lock is stale

fm_pid_alive() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

fm_path_mtime() {  # BSD (-f) vs GNU (-c) stat -- portable across macOS and Linux hosts
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

fm_path_age() {
  local m; m=$(fm_path_mtime "$1") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# fm_singleton_acquire <lockdir>
#   0 = acquired (we hold it; call fm_singleton_release on exit)
#   1 = held by a live process; FM_LOCK_HELD_PID is set to that pid
fm_singleton_acquire() {
  local lockdir=$1 pid
  FM_LOCK_HELD_PID=
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "${BASHPID:-$$}" > "$lockdir/pid" 2>/dev/null || true
    return 0
  fi
  # Lock exists -- is the holder alive?
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  if fm_pid_alive "$pid"; then
    FM_LOCK_HELD_PID=$pid
    return 1
  fi
  # Dead/unreadable pid: reclaim only once it's older than the stale window, so we
  # don't race a holder that just mkdir'd but hasn't written its pid yet.
  case "$pid" in
    ''|*[!0-9]*)
      if [ "$(fm_path_age "$lockdir")" -lt "$FM_LOCK_STALE_AFTER" ]; then
        FM_LOCK_HELD_PID=$pid; return 1
      fi
      ;;
  esac
  rm -f "$lockdir/pid" 2>/dev/null || true
  rmdir "$lockdir" 2>/dev/null || true
  if mkdir "$lockdir" 2>/dev/null; then
    printf '%s\n' "${BASHPID:-$$}" > "$lockdir/pid" 2>/dev/null || true
    return 0
  fi
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  FM_LOCK_HELD_PID=$pid
  return 1
}

# fm_singleton_release <lockdir> -- only the owning pid clears it.
fm_singleton_release() {
  local lockdir=$1 pid
  pid=$(cat "$lockdir/pid" 2>/dev/null || true)
  [ "$pid" = "${BASHPID:-$$}" ] || return 0
  rm -f "$lockdir/pid" 2>/dev/null || true
  rmdir "$lockdir" 2>/dev/null || true
}
