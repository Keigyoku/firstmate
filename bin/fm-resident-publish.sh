#!/usr/bin/env bash
# Publish the Crew Lead's authoritative resident-current pointer.
# Usage: fm-resident-publish.sh [starting|ready|waiting|blocked|degraded|stopped|failed]
# Test/adapter seams: FM_RESIDENT_{HARNESS,SESSION_ID,TRANSCRIPT,TRANSCRIPT_ADAPTER,
# BACKEND_KIND,WORKSPACE_ID,PANE_ID,PID} override automatic discovery.
# Discovers journals for claude, codex, opencode, pi, grok, cursor, hermes under
# FM_HOME (or harness-home env roots). Adapter ids follow Vellum ADR 0056
# (codex-rollout-v1 is the single canonical Codex spelling).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${GOD_NODE_HOME:-${RESIDENT_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
POINTER="$STATE/resident-current.json"
SERIAL="$STATE/resident-current.lock"
LIFECYCLE=${1:-ready}

# shellcheck source=bin/fm-resident-lib.sh
. "$SCRIPT_DIR/fm-resident-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

case "$LIFECYCLE" in
  starting|ready|waiting|blocked|degraded|stopped|failed) ;;
  *) echo "usage: fm-resident-publish.sh [starting|ready|waiting|blocked|degraded|stopped|failed]" >&2; exit 2 ;;
esac

if [ ! -s "$FM_HOME/.god-node/contract.json" ] || [ ! -s "$FM_HOME/.god-node/provision.json" ]; then
  "$SCRIPT_DIR/fm-resident-setup.sh"
fi
CONTAINER_ID=$(fm_resident_container_id "$FM_HOME")
mkdir -p "$STATE"
fm_lock_acquire_wait "$SERIAL"
trap 'fm_lock_release "$SERIAL" 2>/dev/null || true' EXIT

OLD_EPOCH=0
if [ -s "$POINTER" ]; then
  OLD_EPOCH=$(jq -r --arg container_id "$CONTAINER_ID" 'select(.schema == "dev.vellum.resident-current/1" and .container_id == $container_id) | .epoch // 0' "$POINTER" 2>/dev/null || printf 0)
fi
case "$OLD_EPOCH" in ''|*[!0-9]*) OLD_EPOCH=0 ;; esac
EPOCH=$((OLD_EPOCH + 1))
PUBLISHED_AT=$(fm_resident_rfc3339)

# Prefer FM_RESIDENT_HARNESS from Vellum Start / adapter publish; never force claude.
HARNESS=${FM_RESIDENT_HARNESS:-$("$SCRIPT_DIR/fm-harness.sh" 2>/dev/null || printf unknown)}
PID=${FM_RESIDENT_PID:-$(cat "$STATE/.lock" 2>/dev/null || printf '')}
case "$PID" in ''|*[!0-9]*) PID='' ;; esac
CREATION_IDENTITY=''
[ -z "$PID" ] || CREATION_IDENTITY=$(fm_resident_process_identity "$PID" 2>/dev/null || true)

TRANSCRIPT=${FM_RESIDENT_TRANSCRIPT:-}
if [ -z "$TRANSCRIPT" ]; then
  TRANSCRIPT=$(fm_resident_discover_transcript "$HARNESS" "$FM_HOME" 2>/dev/null || true)
fi
SESSION_ID=${FM_RESIDENT_SESSION_ID:-}
if [ -z "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ]; then
  SESSION_ID=$(fm_resident_session_id_from_transcript "$HARNESS" "$TRANSCRIPT" "$FM_HOME" 2>/dev/null || true)
fi
TRANSCRIPT_ADAPTER=${FM_RESIDENT_TRANSCRIPT_ADAPTER:-}
if [ -z "$TRANSCRIPT_ADAPTER" ]; then
  TRANSCRIPT_ADAPTER=$(fm_resident_transcript_adapter "$HARNESS" 2>/dev/null || true)
fi

BACKEND_KIND=${FM_RESIDENT_BACKEND_KIND:-}
[ -n "$BACKEND_KIND" ] || BACKEND_KIND=$(fm_backend_detect 2>/dev/null || true)
WORKSPACE_ID=${FM_RESIDENT_WORKSPACE_ID:-}
PANE_ID=${FM_RESIDENT_PANE_ID:-}
case "$BACKEND_KIND" in
  herdr)
    [ -n "$PANE_ID" ] || PANE_ID=${HERDR_PANE_ID:-}
    [ -n "$WORKSPACE_ID" ] || WORKSPACE_ID=${HERDR_WORKSPACE_ID:-}
    if [ -z "$WORKSPACE_ID" ] && [ -n "$PANE_ID" ] && command -v herdr >/dev/null 2>&1; then
      HERDR_NAME=${HERDR_SESSION:-default}
      WORKSPACE_ID=$(HERDR_SESSION="$HERDR_NAME" herdr --session "$HERDR_NAME" pane get "$PANE_ID" 2>/dev/null \
        | jq -r '.result.pane.workspace_id // empty' 2>/dev/null || true)
    fi
    ;;
  tmux)
    [ -n "$WORKSPACE_ID" ] || WORKSPACE_ID=$(tmux display-message -p '#{session_name}' 2>/dev/null || true)
    [ -n "$PANE_ID" ] || PANE_ID=${TMUX_PANE:-}
    ;;
  cmux)
    [ -n "$WORKSPACE_ID" ] || WORKSPACE_ID=${CMUX_WORKSPACE_ID:-}
    [ -n "$PANE_ID" ] || PANE_ID=${CMUX_SURFACE_ID:-${CMUX_PANEL_ID:-}}
    ;;
esac

BASE=$(jq -n \
  --arg container_id "$CONTAINER_ID" --argjson epoch "$EPOCH" \
  --arg published_at "$PUBLISHED_AT" --arg lifecycle "$LIFECYCLE" \
  '{schema:"dev.vellum.resident-current/1",container_id:$container_id,epoch:$epoch,published_at:$published_at,lifecycle:$lifecycle,resident_type:"firstmate",health:{heartbeat_at:$published_at,detail_code:null}}')

if [ "$LIFECYCLE" != stopped ] && [ -n "$PID" ] && [ -n "$CREATION_IDENTITY" ]; then
  BASE=$(jq --argjson pid "$PID" --arg identity "$CREATION_IDENTITY" '. + {process:{pid:$pid,creation_identity:$identity}}' <<<"$BASE")
fi
if [ "$LIFECYCLE" != stopped ] && [ -n "$BACKEND_KIND" ] && [ -n "$WORKSPACE_ID" ] && [ -n "$PANE_ID" ]; then
  BASE=$(jq --arg kind "$BACKEND_KIND" --arg workspace "$WORKSPACE_ID" --arg pane "$PANE_ID" '. + {backend:{kind:$kind,workspace_id:$workspace,pane_id:$pane},input:{transport:"backend-v1",target:{workspace_id:$workspace,pane_id:$pane}}}' <<<"$BASE")
else
  BASE=$(jq '. + {input:{transport:"file-v1",target:{requests:"inbox/requests",results:"inbox/results"}}}' <<<"$BASE")
fi
if [ "$LIFECYCLE" != stopped ] && [ -n "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ] && [ -n "$TRANSCRIPT_ADAPTER" ]; then
  BASE=$(jq --arg harness "$HARNESS" --arg session "$SESSION_ID" --arg adapter "$TRANSCRIPT_ADAPTER" --arg transcript "$TRANSCRIPT" '. + {conversation:{harness:$harness,session_id:$session,transcript:{adapter:$adapter,id:$session,path:$transcript}}}' <<<"$BASE")
fi

printf '%s\n' "$BASE" | fm_resident_atomic_json "$POINTER"
