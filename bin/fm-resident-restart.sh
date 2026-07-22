#!/usr/bin/env bash
# Re-publish the current Crew Lead session through the session-lock authority.
#
# Usage:
#   fm-resident-restart.sh
#     Lock-only re-publish (same as fm-lock / default start). Does not start an
#     agent process.
#
#   fm-resident-restart.sh --launch <cmd> [args...]
#     Same as fm-resident-start.sh --launch: setup+publish with this PID, then
#     exec the harness. Use when Crew Lead Restart must relaunch the agent;
#     otherwise prefer Start with --launch and keep Restart lock-only.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--launch" ]; then
  # Share the start entrypath implementation so Start and Restart cannot drift.
  # "$@" already begins with --launch.
  exec "$SCRIPT_DIR/fm-resident-start.sh" "$@"
fi

"$SCRIPT_DIR/fm-lock.sh"
