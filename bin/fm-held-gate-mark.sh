#!/usr/bin/env bash
# Thin wrapper: after firstmate relays an ask-user gate to the captain, park the
# crew only when the authoritative run-step still verifies that gate.
# The run-step check is this wrapper's precondition; the park marker itself is
# the absorb fact (see bin/fm-park.sh and docs/architecture.md).
# Usage: fm-held-gate-mark.sh <task-id>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

ID=${1:-}
case "$ID" in
  ''|*[!A-Za-z0-9._-]*)
    echo "usage: fm-held-gate-mark.sh <task-id>" >&2
    exit 2
    ;;
esac

if [ ! -f "$STATE/$ID.meta" ]; then
  echo "error: no meta for task $ID at $STATE/$ID.meta" >&2
  exit 1
fi

if ! mark_held_gate_if_verified "$ID"; then
  echo "error: task $ID is not parked at a verified ask-user run-step" >&2
  exit 1
fi
