#!/usr/bin/env bash
# Enter away mode and run the sub-supervisor daemon in a harness-tracked
# foreground process when one is not already alive.
#
# Usage: fm-afk-start.sh
#   Checks state/.supervise-daemon.lock, and:
#     - refreshes state/.afk, prints "afk: daemon already running pid=<pid>",
#       then exits 0 when that lock is held by a live daemon;
#     - otherwise execs bin/fm-supervise-daemon.sh in the foreground.
#
# Run this command as its own tracked background terminal/session.
# Do not wrap it in `nohup ... &`: Codex/herdr can reap fire-and-forget shell
# children after the tool call returns, while a tracked background command stays
# attached to the harness and has a real lifecycle.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.supervise-daemon.lock"
DAEMON="$SCRIPT_DIR/fm-supervise-daemon.sh"

usage() {
  sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  '' ) ;;
  -h|--help) usage; exit 0 ;;
  * ) echo "usage: $(basename "$0")" >&2; exit 2 ;;
esac

mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
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
  # Refresh afk, then re-prove the inject channel. A live daemon whose composer
  # is permanently pending (the 2026-07-24 app-spawned Claude wedge) must not
  # look healthy just because the process is still running.
  date '+%s' > "$STATE/.afk"
  if ! inject_channel_self_test "$STATE"; then
    echo "error: AFK inject channel self-test FAILED while daemon pid=$pid is live - do not trust away-mode until the channel is fixed (see state/.subsuper-inject-wedged)" >&2
    exit 1
  fi
  echo "afk: daemon already running pid=$pid; inject channel self-test OK"
  exit 0
fi

if fm_pid_alive "$pid" && [ -n "$pid" ]; then
  fm_lock_remove_path "$LOCK" 2>/dev/null || true
fi

date '+%s' > "$STATE/.afk"
echo "afk: starting supervise daemon in foreground; keep this command as a tracked background session"
echo "afk: inject channel self-test runs at daemon startup (fails loud if the supervisor pane cannot accept escalations)"
exec "$DAEMON"
