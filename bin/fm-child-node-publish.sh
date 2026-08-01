#!/usr/bin/env bash
# Publish the Child Node atomic current-state pointer (CN-P birth + later updates).
# Usage: fm-child-node-publish.sh <task-id> [lifecycle]
#
# Lifecycle values: starting|ready|waiting|blocked|degraded|stopped|failed|done.
# When lifecycle is omitted and a matching pointer already exists, the previous
# lifecycle is preserved (status/turn-end conversation-completion refresh).
# Otherwise the first publish defaults to starting.
#
# Writes crews/<task-id>/state/child-current.json using the same validate+rename
# atomic pattern as resident-current (fm_resident_atomic_json).
# parent_container_id always echoes the God Node provision id and the child
# descriptor parent.container_id (fail closed on mismatch).
#
# Test/adapter seams: FM_CHILD_{BACKEND_KIND,WORKSPACE_ID,PANE_ID,PID,STATUS_VERB,STATUS_NOTE}
# Optional identity hints: FM_CHILD_{HARNESS,WORKTREE} override state/<task-id>.meta.
# Optional conversation override: FM_CHILD_{SESSION_ID,TRANSCRIPT} (regular file only).
# Nested conversation is published only when harness, session_id, adapter, and a
# verified-real absolute transcript path are all knowable - never invent.
# Top-level harness/worktree remain additive per-field hints (never invent).
# When env omits backend/status/pid on a refresh, prior objects are kept verbatim.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${GOD_NODE_HOME:-${RESIDENT_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}}"

# shellcheck source=bin/fm-child-node-lib.sh
. "$SCRIPT_DIR/fm-child-node-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# Read one key=value line from task meta (last wins). Empty when meta or key is absent.
fm_child_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2
  [ -f "$meta" ] || return 0
  grep "^${key}=" "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_child_real_file_path() {  # <path>
  local path=$1 resolved
  case "$path" in /*) ;; *) return 1 ;; esac
  [ -f "$path" ] || return 1
  if command -v realpath >/dev/null 2>&1; then
    resolved=$(realpath "$path" 2>/dev/null) || return 1
  elif command -v python3 >/dev/null 2>&1; then
    resolved=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
      "$path" 2>/dev/null) || return 1
  else
    return 1
  fi
  case "$resolved" in /*) ;; *) return 1 ;; esac
  [ -f "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
}

TASK_ID=
LIFECYCLE=
LIFECYCLE_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    starting|ready|waiting|blocked|degraded|stopped|failed|done)
      LIFECYCLE=$1
      LIFECYCLE_SET=1
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
if [ "$LIFECYCLE_SET" -eq 1 ]; then
  case "$LIFECYCLE" in
    starting|ready|waiting|blocked|degraded|stopped|failed|done) ;;
    *) echo "usage: fm-child-node-publish.sh <task-id> [starting|ready|waiting|blocked|degraded|stopped|failed|done]" >&2; exit 2 ;;
  esac
fi

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
PREV_LIFECYCLE=
PREV_BACKEND=
PREV_ATTESTATION=
PREV_STATUS=
PREV_PROCESS=
if [ -s "$POINTER" ]; then
  OLD_EPOCH=$(jq -r --arg container_id "$CONTAINER_ID" \
    'select(.schema == "dev.vellum.child-current/1" and .container_id == $container_id) | .epoch // 0' \
    "$POINTER" 2>/dev/null || printf 0)
  PREV_LIFECYCLE=$(jq -r --arg container_id "$CONTAINER_ID" \
    'select(.schema == "dev.vellum.child-current/1" and .container_id == $container_id) | .lifecycle // empty' \
    "$POINTER" 2>/dev/null || true)
  if [ "$LIFECYCLE_SET" -eq 0 ]; then
    PREV_BACKEND=$(jq -c --arg container_id "$CONTAINER_ID" \
      'select(.schema == "dev.vellum.child-current/1" and .container_id == $container_id) | .backend // empty' \
      "$POINTER" 2>/dev/null || true)
    PREV_ATTESTATION=$(jq -c --arg container_id "$CONTAINER_ID" \
      'select(.schema == "dev.vellum.child-current/1" and .container_id == $container_id) | .attestation // empty' \
      "$POINTER" 2>/dev/null || true)
    PREV_STATUS=$(jq -c --arg container_id "$CONTAINER_ID" \
      'select(.schema == "dev.vellum.child-current/1" and .container_id == $container_id) | .status // empty' \
      "$POINTER" 2>/dev/null || true)
    PREV_PROCESS=$(jq -c --arg container_id "$CONTAINER_ID" \
      'select(.schema == "dev.vellum.child-current/1" and .container_id == $container_id) | .process // empty' \
      "$POINTER" 2>/dev/null || true)
  fi
fi
case "$OLD_EPOCH" in ''|*[!0-9]*) OLD_EPOCH=0 ;; esac
EPOCH=$((OLD_EPOCH + 1))
PUBLISHED_AT=$(fm_resident_rfc3339)

if [ "$LIFECYCLE_SET" -eq 0 ]; then
  if [ -n "$PREV_LIFECYCLE" ]; then
    LIFECYCLE=$PREV_LIFECYCLE
  else
    LIFECYCLE=starting
  fi
fi
case "$LIFECYCLE" in
  starting|ready|waiting|blocked|degraded|stopped|failed|done) ;;
  *) LIFECYCLE=starting ;;
esac

BACKEND_KIND=${FM_CHILD_BACKEND_KIND:-}
WORKSPACE_ID=${FM_CHILD_WORKSPACE_ID:-}
PANE_ID=${FM_CHILD_PANE_ID:-}
PID=${FM_CHILD_PID:-}
STATUS_VERB=${FM_CHILD_STATUS_VERB:-}
STATUS_NOTE=${FM_CHILD_STATUS_NOTE:-}

BACKEND_SUPPLIED=0
STATUS_SUPPLIED=0
PROCESS_SUPPLIED=0
[ -z "$BACKEND_KIND$WORKSPACE_ID$PANE_ID" ] || BACKEND_SUPPLIED=1
[ -z "$STATUS_VERB$STATUS_NOTE" ] || STATUS_SUPPLIED=1
[ -z "$PID" ] || PROCESS_SUPPLIED=1

case "$PID" in ''|*[!0-9]*) PID='' ;; esac
CREATION_IDENTITY=''
[ -z "$PID" ] || CREATION_IDENTITY=$(fm_resident_process_identity "$PID" 2>/dev/null || true)

# Top-level identity hints: known values from task meta (or env override).
# Omit when genuinely unknown - never default to claude or invent a cwd.
TASK_META="${FM_STATE_OVERRIDE:-${STATE:-$FM_HOME/state}}/$TASK_ID.meta"
HARNESS=${FM_CHILD_HARNESS:-}
WORKTREE=${FM_CHILD_WORKTREE:-}
if [ -z "$HARNESS" ]; then
  HARNESS=$(fm_child_meta_get "$TASK_META" harness)
fi
if [ -z "$WORKTREE" ]; then
  WORKTREE=$(fm_child_meta_get "$TASK_META" worktree)
fi
# Physical absolute spelling for worktree when the path exists (/var/home, not /home).
if [ -n "$WORKTREE" ] && [ -e "$WORKTREE" ]; then
  WORKTREE=$(fm_resident_canonical_path "$WORKTREE")
fi

# Nested conversation (full bind): only when every field is knowable and the
# transcript path is a verified-real absolute file. Reuses resident ADR 0056
# discovery. Env FM_CHILD_TRANSCRIPT / FM_CHILD_SESSION_ID override discovery.
SESSION_ID=${FM_CHILD_SESSION_ID:-}
TRANSCRIPT=${FM_CHILD_TRANSCRIPT:-}
TRANSCRIPT_ADAPTER=
if [ -n "$HARNESS" ]; then
  TRANSCRIPT_ADAPTER=$(fm_resident_transcript_adapter "$HARNESS" 2>/dev/null || true)
fi
if [ -n "$HARNESS" ] && [ -n "$WORKTREE" ] && [ -z "$TRANSCRIPT" ]; then
  TRANSCRIPT=$(fm_resident_discover_transcript "$HARNESS" "$WORKTREE" 2>/dev/null || true)
fi
TRANSCRIPT=$(fm_child_real_file_path "$TRANSCRIPT" 2>/dev/null || true)
if [ -z "$SESSION_ID" ] && [ -n "$HARNESS" ] && [ -n "$TRANSCRIPT" ]; then
  case "$HARNESS" in
    opencode|hermes)
      if [ -n "$WORKTREE" ]; then
        SESSION_ID=$(fm_resident_session_id_from_transcript \
          "$HARNESS" "$TRANSCRIPT" "$WORKTREE" 2>/dev/null || true)
      fi
      ;;
    *)
      SESSION_ID=$(fm_resident_session_id_from_transcript \
        "$HARNESS" "$TRANSCRIPT" 2>/dev/null || true)
      ;;
  esac
fi

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
elif [ "$LIFECYCLE" != stopped ] && [ "$PROCESS_SUPPLIED" -eq 0 ] && [ -n "$PREV_PROCESS" ]; then
  BASE=$(jq --argjson process "$PREV_PROCESS" '. + {process:$process}' <<<"$BASE")
fi

if [ "$LIFECYCLE" != stopped ] && [ -n "$BACKEND_KIND" ] && [ -n "$WORKSPACE_ID" ] && [ -n "$PANE_ID" ]; then
  BASE=$(jq --arg kind "$BACKEND_KIND" --arg workspace "$WORKSPACE_ID" --arg pane "$PANE_ID" \
    --arg published_at "$PUBLISHED_AT" \
    '. + {backend:{kind:$kind,workspace_id:$workspace,pane_id:$pane},attestation:{method:"backend-pane-v1",observed_at:$published_at}}' \
    <<<"$BASE")
elif [ "$LIFECYCLE" != stopped ] && [ "$BACKEND_SUPPLIED" -eq 0 ]; then
  if [ -n "$PREV_BACKEND" ]; then
    BASE=$(jq --argjson backend "$PREV_BACKEND" '. + {backend:$backend}' <<<"$BASE")
  fi
  if [ -n "$PREV_ATTESTATION" ]; then
    BASE=$(jq --argjson attestation "$PREV_ATTESTATION" \
      '. + {attestation:$attestation}' <<<"$BASE")
  fi
fi

if [ -n "$STATUS_VERB" ]; then
  BASE=$(jq --arg verb "$STATUS_VERB" --arg note "$STATUS_NOTE" --arg at "$PUBLISHED_AT" \
    '. + {status:{verb:$verb,note:$note,at:$at}}' <<<"$BASE")
elif [ "$STATUS_SUPPLIED" -eq 0 ] && [ -n "$PREV_STATUS" ]; then
  BASE=$(jq --argjson status "$PREV_STATUS" '. + {status:$status}' <<<"$BASE")
fi

if [ -n "$HARNESS" ]; then
  BASE=$(jq --arg harness "$HARNESS" '. + {harness:$harness}' <<<"$BASE")
fi
if [ -n "$WORKTREE" ]; then
  BASE=$(jq --arg worktree "$WORKTREE" '. + {worktree:$worktree}' <<<"$BASE")
fi

# Full nested conversation only when complete; omit the object otherwise.
if [ "$LIFECYCLE" != stopped ] \
  && [ -n "$HARNESS" ] \
  && [ -n "$SESSION_ID" ] \
  && [ -n "$TRANSCRIPT" ] \
  && [ -n "$TRANSCRIPT_ADAPTER" ]; then
  BASE=$(jq --arg harness "$HARNESS" --arg session "$SESSION_ID" \
    --arg adapter "$TRANSCRIPT_ADAPTER" --arg path "$TRANSCRIPT" \
    '. + {conversation:{harness:$harness,session_id:$session,transcript:{adapter:$adapter,id:$session,path:$path}}}' \
    <<<"$BASE")
fi

printf '%s\n' "$BASE" | fm_resident_atomic_json "$POINTER"
