#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"

if fm_watchdog_compact_pending_identity_current \
  "${FM_COMPACT_GUARD_TASK:?}" \
  "${FM_COMPACT_GUARD_HARNESS:?}" \
  "${FM_COMPACT_GUARD_PENDING:?}"; then
  exit 0
else
  rc=$?
fi

case "$rc" in
  1) exit 10 ;;
  *) exit 11 ;;
esac
