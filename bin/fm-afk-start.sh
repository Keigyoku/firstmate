#!/usr/bin/env bash
# Enter away mode and ensure the sub-supervisor daemon is running and still
# alive after a short settle window.
#
# Usage: fm-afk-start.sh
#   Checks state/.supervise-daemon.lock, and:
#     - refreshes state/.afk, probes the inject channel (no concurrent inject),
#       prints "afk: daemon already running pid=<pid>", exits 0 when a live
#       identity-backed daemon holds the lock;
#     - otherwise sets state/.afk, starts bin/fm-supervise-daemon.sh in a new
#       session so a reaped harness background task cannot take the daemon with
#       it, waits for the pid file, settles FM_AFK_START_SETTLE_SECS (default 3),
#       and fails LOUD if the daemon is already dead (start-then-die) or if
#       startup cleared .afk (self-test failed).
#
# Why detach (2026-07-25 evidence): exec'ing the daemon in a Claude tracked
# background task made the daemon die when the harness reaped that task, while
# state/.afk stayed set - silent hole (flag on, nothing triages). Session
# detachment plus the parent settle-check proves the process is still alive.
#
# FM_AFK_START_SETTLE_SECS  seconds to wait after pid file appears before the
#                          still-alive check (default 3).
# FM_AFK_START_FOREGROUND=1  legacy: exec the daemon in the foreground instead
#                          of detaching (e2e / callers that own the process).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.supervise-daemon.lock"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"
SETTLE_SECS=${FM_AFK_START_SETTLE_SECS:-3}
case "$SETTLE_SECS" in ''|*[!0-9]*) SETTLE_SECS=3 ;; esac

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '' ) ;;
  -h|--help) usage; exit 0 ;;
  * ) echo "usage: $(basename "$0")" >&2; exit 2 ;;
esac

mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if [ "${FM_WEDGE_ALARM_EXEC:-}" = discard ]; then
  unset FM_WEDGE_ALARM_EXEC
fi
# shellcheck source=bin/fm-supervise-daemon.sh
load_daemon_library() {
  local FM_WEDGE_ALARM_ALLOW_LIVE=1
  . "$DAEMON"
}
load_daemon_library
unset -f load_daemon_library

daemon_lock_owner() {
  local owner
  if [ -L "$LOCK" ]; then
    owner=$(readlink "$LOCK" 2>/dev/null) || return 1
    [ -n "$owner" ] || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$(dirname "$LOCK")" "$owner" ;;
    esac
    return 0
  fi
  [ -d "$LOCK" ] || return 1
  printf '%s\n' "$LOCK"
}

daemon_pid_matches() {
  local pid=$1 owner=$2 identity current command
  identity=$(cat "$owner/pid-identity" 2>/dev/null || true)
  if [ -n "$identity" ]; then
    current=$(fm_pid_identity "$pid") || return 1
    [ "$current" = "$identity" ]
    return
  fi
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$DAEMON"*|*"fm-supervise-daemon.sh"*) return 0 ;;
  esac
  return 1
}

daemon_lock_pid() {
  local owner
  owner=$(daemon_lock_owner) || return 1
  cat "$owner/pid" 2>/dev/null || true
}

daemon_lock_held_by_live_daemon() {
  local owner pid
  owner=$(daemon_lock_owner) || return 1
  pid=$(cat "$owner/pid" 2>/dev/null || true)
  fm_pid_alive "$pid" || return 1
  daemon_pid_matches "$pid" "$owner"
}

# Fail loud when activation leaves .afk set but the daemon is gone (start-then-
# die, or harness reaped the process before detach). Clears the lie (.afk) so
# session-start does not report healthy away-mode with no supervisor.
afk_start_fail_daemon_dead() {  # <reason>
  local reason=$1 pid
  pid=$(daemon_lock_pid 2>/dev/null || true)
  {
    printf 'fm away-mode inject WEDGED as of %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    printf 'reason: AFK_DAEMON_DEAD: %s\n' "$reason"
    printf 'pid_file=%s lock=%s\n' "${pid:-none}" "$LOCK"
    printf 'state/.afk was set with no live supervise daemon - silent triage hole\n'
  } > "$STATE/.subsuper-inject-wedged" 2>/dev/null || true
  rm -f "$STATE/.afk" 2>/dev/null || true
  printf 'error: AFK_DAEMON_DEAD: %s\n' "$reason" >&2
  printf 'error: cleared state/.afk (flag-on-daemon-dead is a silent hole); see %s\n' \
    "$STATE/.subsuper-inject-wedged" >&2
  return 1
}

# Resolve supervisor backend/target before claiming afk healthy. Used both for
# the already-running re-probe and for the start path's preflight.
backend=$(discover_supervisor_backend) || true
if ! fm_backend_list_contains "$FM_SUPERVISOR_SUPPORTED_BACKENDS" "$backend"; then
  echo "error: away-mode daemon does not support supervisor backend '$backend' yet (supported: $FM_SUPERVISOR_SUPPORTED_BACKENDS); set FM_SUPERVISOR_BACKEND=tmux|herdr and FM_SUPERVISOR_TARGET to run firstmate's own pane under a supported backend" >&2
  exit 1
fi
FM_SUPERVISOR_BACKEND="$backend"
export FM_SUPERVISOR_BACKEND

target=$(discover_supervisor_target) || true
if ! fm_backend_target_exists "$backend" "$target"; then
  echo "error: supervisor target '$target' does not resolve to a $backend pane; set FM_SUPERVISOR_TARGET" >&2
  exit 1
fi
FM_SUPERVISOR_TARGET="$target"
export FM_SUPERVISOR_TARGET

pid=$(daemon_lock_pid 2>/dev/null || true)
if daemon_lock_held_by_live_daemon; then
  # Refresh afk, then probe channel availability without writing from this
  # process. The running daemon remains the sole injector.
  date '+%s' > "$STATE/.afk"
  if ! inject_channel_probe "$STATE" "live-daemon probe"; then
    echo "error: AFK inject channel probe FAILED while daemon pid=$pid is live - do not trust away-mode until the channel is fixed (see state/.subsuper-inject-wedged)" >&2
    exit 1
  fi
  echo "afk: daemon already running pid=$pid; inject channel probe OK"
  exit 0
fi

if fm_pid_alive "$pid" && [ -n "$pid" ]; then
  fm_lock_remove_path "$LOCK" 2>/dev/null || true
fi

date '+%s' > "$STATE/.afk"

# Legacy foreground path for e2e / callers that own the process lifecycle.
if [ "${FM_AFK_START_FOREGROUND:-0}" = 1 ]; then
  echo "afk: starting supervise daemon in foreground (FM_AFK_START_FOREGROUND=1)"
  echo "afk: inject channel self-test runs at daemon startup (fails loud if the supervisor pane cannot accept escalations)"
  exec "$DAEMON"
fi

launch_daemon_detached() {
  if command -v setsid >/dev/null 2>&1; then
    DETACH_METHOD=setsid
    setsid "$DAEMON" </dev/null \
      >>"$STATE/.supervise-daemon.stdout" 2>>"$STATE/.supervise-daemon.stderr" &
  elif command -v python3 >/dev/null 2>&1; then
    DETACH_METHOD=python3-os.setsid
    python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
      "$DAEMON" </dev/null \
      >>"$STATE/.supervise-daemon.stdout" 2>>"$STATE/.supervise-daemon.stderr" &
  elif command -v perl >/dev/null 2>&1; then
    DETACH_METHOD=perl-POSIX-setsid
    perl -MPOSIX -e 'POSIX::setsid() >= 0 or die "setsid failed: $!"; exec @ARGV or die "exec failed: $!"' \
      "$DAEMON" </dev/null \
      >>"$STATE/.supervise-daemon.stdout" 2>>"$STATE/.supervise-daemon.stderr" &
  elif command -v python >/dev/null 2>&1; then
    DETACH_METHOD=python-os.setsid
    python -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
      "$DAEMON" </dev/null \
      >>"$STATE/.supervise-daemon.stdout" 2>>"$STATE/.supervise-daemon.stderr" &
  else
    echo "error: cannot detach supervise daemon: need setsid, python3, perl, or python" >&2
    afk_start_fail_daemon_dead "no session-detachment command available"
    return 1
  fi
  DAEMON_START_PID=$!
}

DETACH_METHOD=
DAEMON_START_PID=
launch_daemon_detached || exit 1

echo "afk: starting supervise daemon detached ($DETACH_METHOD); parent will verify still-alive after ${SETTLE_SECS}s settle"
echo "afk: inject channel self-test runs at daemon startup (fails loud if the supervisor pane cannot accept escalations)"

# Wait for the daemon to publish its pid file (startup + lock acquire).
i=0
while [ "$i" -lt 50 ]; do
  if [ -f "$STATE/.supervise-daemon.pid" ]; then
    break
  fi
  # If starter already exited with failure, surface stderr.
  if ! kill -0 "$DAEMON_START_PID" 2>/dev/null && [ ! -f "$STATE/.supervise-daemon.pid" ]; then
    echo "error: supervise daemon exited before writing pid file" >&2
    [ -s "$STATE/.supervise-daemon.stderr" ] && sed -n '1,40p' "$STATE/.supervise-daemon.stderr" >&2
    [ -s "$STATE/.supervise-daemon.log" ] && tail -n 20 "$STATE/.supervise-daemon.log" >&2
    afk_start_fail_daemon_dead "daemon exited before pid file (startup self-test or preflight failed?)"
    exit 1
  fi
  sleep 0.2
  i=$((i + 1))
done

if [ ! -f "$STATE/.supervise-daemon.pid" ]; then
  afk_start_fail_daemon_dead "no pid file after 10s waiting for daemon startup"
  exit 1
fi

# Post-start still-alive check: start-then-die is invisible if we only verify
# "started". Sleep the settle window, then re-check identity-backed liveness.
sleep "$SETTLE_SECS"

if ! daemon_lock_held_by_live_daemon; then
  afk_start_fail_daemon_dead "daemon not live after ${SETTLE_SECS}s settle (start-then-die / harness reaped the process)"
  exit 1
fi

# Daemon self-test failure clears .afk and exits; detect that explicitly.
if [ ! -e "$STATE/.afk" ]; then
  echo "error: AFK inject self-test or startup cleared state/.afk - away-mode refused" >&2
  [ -s "$STATE/.subsuper-inject-wedged" ] && sed -n '1,15p' "$STATE/.subsuper-inject-wedged" >&2
  exit 1
fi

live_pid=$(daemon_lock_pid 2>/dev/null || true)
echo "afk: daemon live pid=${live_pid:-?} after ${SETTLE_SECS}s settle; away-mode active"
exit 0
