#!/usr/bin/env bash
# Publish the current Crew Lead session without starting a parallel tracker.
#
# Usage:
#   fm-resident-start.sh
#     Acquire the session lock and publish resident-current (same as fm-lock).
#     For sessions that already run a harness (primary firstmate). Lock-only;
#     does not start an agent process.
#
#   fm-resident-start.sh --launch <cmd> [args...]
#     After successful setup + publish with this process as the lock holder,
#     exec <cmd> so the pane's agent process is this entrypath → harness.
#     exec replaces the shell image under the same PID, so state/.lock and
#     resident-current process.pid stay honest for the live harness without a
#     leftover start shell. Crew Lead / Vellum agent.start should use:
#       bin/fm-resident-start.sh --launch <harness> [harness-args...]
#     from the Crew Lead home. When FM_RESIDENT_HARNESS is unset, the basename
#     of <cmd> is used for publish (override if the basename is not a verified
#     adapter name).
#
# Restart: bin/fm-resident-restart.sh accepts the same --launch form when Crew
# Lead Restart must relaunch the harness; without --launch both stay lock-only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--launch" ]; then
  shift
  if [ "$#" -lt 1 ]; then
    echo "usage: fm-resident-start.sh --launch <cmd> [args...]" >&2
    exit 2
  fi
  launch_cmd=$1
  shift
  case "$launch_cmd" in
    */*) launch_path=$launch_cmd ;;
    *) launch_path=$(command -v -- "$launch_cmd" 2>/dev/null || true) ;;
  esac
  if [ -z "$launch_path" ] || [ ! -f "$launch_path" ] || [ ! -x "$launch_path" ]; then
    echo "error: cannot launch executable file: $launch_cmd" >&2
    exit 1
  fi
  if [ -z "${FM_RESIDENT_HARNESS:-}" ]; then
    FM_RESIDENT_HARNESS=$(basename -- "$launch_cmd")
    export FM_RESIDENT_HARNESS
  fi
  # Pre-exec: this PID becomes the harness after exec; ancestry has no harness yet.
  export FM_LOCK_PID=$$
  "$SCRIPT_DIR/fm-lock.sh" || exit $?
  launch_state=${FM_STATE_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}/state}
  shopt -s execfail
  exec "$launch_path" "$@" || {
    launch_status=$?
    FM_RESIDENT_PID=$$ "$SCRIPT_DIR/fm-resident-publish.sh" stopped >/dev/null 2>&1 || true
    if [ "$(cat "$launch_state/.lock" 2>/dev/null || true)" = "$$" ]; then
      rm -f "$launch_state/.lock"
    fi
    echo "error: failed to launch: $launch_cmd" >&2
    exit "$launch_status"
  }
fi

"$SCRIPT_DIR/fm-lock.sh"
