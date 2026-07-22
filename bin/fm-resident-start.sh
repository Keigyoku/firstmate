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
  # Resolve PATH for bare names before taking the lock so a missing binary
  # fails closed without stranding a half-published session.
  if [ -e "$launch_cmd" ] || [ -x "$launch_cmd" ]; then
    :
  elif command -v "$launch_cmd" >/dev/null 2>&1; then
    :
  else
    echo "error: cannot launch: $launch_cmd not found on PATH" >&2
    exit 1
  fi
  if [ -z "${FM_RESIDENT_HARNESS:-}" ]; then
    FM_RESIDENT_HARNESS=$(basename -- "$launch_cmd")
    export FM_RESIDENT_HARNESS
  fi
  # Pre-exec: this PID becomes the harness after exec; ancestry has no harness yet.
  export FM_LOCK_PID=$$
  "$SCRIPT_DIR/fm-lock.sh" || exit $?
  exec "$launch_cmd" "$@"
fi

"$SCRIPT_DIR/fm-lock.sh"
