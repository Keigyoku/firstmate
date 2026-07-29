#!/usr/bin/env bash
# Publish the Child Node atomic current-state pointer (CN-P birth + later updates).
# Usage: fm-child-node-publish.sh <task-id> [starting|ready|waiting|blocked|degraded|stopped|failed|done]
#
# Writes crews/<task-id>/state/child-current.json using the same validate+rename
# atomic pattern as resident-current (fm_resident_atomic_json).
# parent_container_id always echoes the God Node provision id and the child
# descriptor parent.container_id (fail closed on mismatch).
#
# Test/adapter seams: FM_CHILD_{BACKEND_KIND,WORKSPACE_ID,PANE_ID,PID,STATUS_VERB,STATUS_NOTE}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${GOD_NODE_HOME:-${RESIDENT_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}}"

# shellcheck source=bin/fm-child-node-lib.sh
. "$SCRIPT_DIR/fm-child-node-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

TASK_ID=
LIFECYCLE=starting
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    starting|ready|waiting|blocked|degraded|stopped|failed|done)
      LIFECYCLE=$1
      shift
      ;;
    -*)
      echo "fm-child-node-publish: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$TASK_ID" ]; then
        TASK_ID=$1
        shift
      else
        echo "fm-child-node-publish: unexpected argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

[ -n "$TASK_ID" ] || { echo "usage: fm-child-node-publish.sh <task-id> [lifecycle]" >&2; exit 2; }
case "$TASK_ID" in
  */*|*..*|"") echo "fm-child-node-publish: invalid task id: $TASK_ID" >&2; exit 2 ;;
esac
case "$LIFECYCLE" in
  starting|ready|waiting|blocked|degraded|stopped|failed|done) ;;
  *) echo "usage: fm-child-node-publish.sh <task-id> [starting|ready|waiting|blocked|degraded|stopped|failed|done]" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-child-node-publish: jq is required" >&2; exit 1; }

CHILD_HOME=$(fm_child_node_home "$FM_HOME" "$TASK_ID")
CONTRACT="$CHILD_HOME/.child-node/contract.json"
PROVISION="$CHILD_HOME/.child-node/provision.json"
CHILD="$CHILD_HOME/.child-node/child.json"
POINTER="$CHILD_HOME/state/child-current.json"
SERIAL="$CHILD_HOME/state/child-current.lock"

if [ ! -s "$CONTRACT" ] || [ ! -s "$PROVISION" ] || [ ! -s "$CHILD" ]; then
  echo "fm-child-node-publish: Child Node docs missing under $CHILD_HOME/.child-node; run fm-child-node-setup.sh first" >&2
  exit 1
fi

CONTAINER_ID=$(fm_child_node_container_id "$CHILD_HOME") || {
  echo "fm-child-node-publish: provision.json unreadable" >&2
  exit 1
}

PARENT_ID=$(fm_resident_container_id "$FM_HOME") || {
  echo "fm-child-node-publish: parent God Node provision missing" >&2
  exit 1
}
DESC_PARENT=$(jq -er 'select(.schema == "dev.vellum.child/1") | .parent.container_id' "$CHILD") || {
  echo "fm-child-node-publish: child.json parent.container_id missing" >&2
  exit 1
}
if [ "$DESC_PARENT" != "$PARENT_ID" ]; then
  echo "fm-child-node-publish: child descriptor parent does not match God Node provision" >&2
  exit 1
fi

CHILD_TYPE=$(jq -er 'select(.schema == "dev.vellum.child/1") | .child_type' "$CHILD")

mkdir -p "$CHILD_HOME/state"
fm_lock_acquire_wait "$SERIAL"
trap 'fm_lock_release "$SERIAL" 2>/dev/null || true' EXIT

OLD_EPOCH=0
if [ -s "$POINTER" ]; then
  OLD_EPOCH=$(jq -r --arg container_id "$CONTAINER_ID" \
    'select(.schema == "dev.vellum.child-current/1" and .container_id == $container_id) | .epoch // 0' \
    "$POINTER" 2>/dev/null || printf 0)
fi
case "$OLD_EPOCH" in ''|*[!0-9]*) OLD_EPOCH=0 ;; esac
EPOCH=$((OLD_EPOCH + 1))
PUBLISHED_AT=$(fm_resident_rfc3339)

BACKEND_KIND=${FM_CHILD_BACKEND_KIND:-}
WORKSPACE_ID=${FM_CHILD_WORKSPACE_ID:-}
PANE_ID=${FM_CHILD_PANE_ID:-}
PID=${FM_CHILD_PID:-}
case "$PID" in ''|*[!0-9]*) PID='' ;; esac
CREATION_IDENTITY=''
[ -z "$PID" ] || CREATION_IDENTITY=$(fm_resident_process_identity "$PID" 2>/dev/null || true)

STATUS_VERB=${FM_CHILD_STATUS_VERB:-}
STATUS_NOTE=${FM_CHILD_STATUS_NOTE:-}

BASE=$(jq -n \
  --arg container_id "$CONTAINER_ID" \
  --arg parent_id "$PARENT_ID" \
  --argjson epoch "$EPOCH" \
  --arg published_at "$PUBLISHED_AT" \
  --arg lifecycle "$LIFECYCLE" \
  --arg child_type "$CHILD_TYPE" \
  --arg task_id "$TASK_ID" \
  '{
    schema:"dev.vellum.child-current/1",
    container_id:$container_id,
    parent_container_id:$parent_id,
    epoch:$epoch,
    published_at:$published_at,
    lifecycle:$lifecycle,
    child_type:$child_type,
    task_id:$task_id
  }')

if [ "$LIFECYCLE" != stopped ] && [ -n "$PID" ] && [ -n "$CREATION_IDENTITY" ]; then
  BASE=$(jq --argjson pid "$PID" --arg identity "$CREATION_IDENTITY" \
    '. + {process:{pid:$pid,creation_identity:$identity}}' <<<"$BASE")
fi

if [ "$LIFECYCLE" != stopped ] && [ -n "$BACKEND_KIND" ] && [ -n "$WORKSPACE_ID" ] && [ -n "$PANE_ID" ]; then
  BASE=$(jq --arg kind "$BACKEND_KIND" --arg workspace "$WORKSPACE_ID" --arg pane "$PANE_ID" \
    --arg published_at "$PUBLISHED_AT" \
    '. + {backend:{kind:$kind,workspace_id:$workspace,pane_id:$pane},attestation:{method:"backend-pane-v1",observed_at:$published_at}}' \
    <<<"$BASE")
fi

if [ -n "$STATUS_VERB" ]; then
  BASE=$(jq --arg verb "$STATUS_VERB" --arg note "$STATUS_NOTE" --arg at "$PUBLISHED_AT" \
    '. + {status:{verb:$verb,note:$note,at:$at}}' <<<"$BASE")
fi

printf '%s\n' "$BASE" | fm_resident_atomic_json "$POINTER"
