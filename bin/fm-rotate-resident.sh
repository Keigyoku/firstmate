#!/usr/bin/env bash
# Manually rotate the task resident in this backend endpoint through the watchdog successor path.
# Usage: fm-rotate-resident.sh [--dry-run]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-watchdog-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-watchdog-lib.sh"

usage() {
  echo "usage: fm-rotate-resident.sh [--dry-run]" >&2
}

fail() {
  echo "fm-rotate-resident: $*" >&2
  exit 1
}

resident_endpoint() {
  if [ -n "${FM_RESIDENT_TARGET:-}" ]; then
    printf '%s\n' "$FM_RESIDENT_TARGET"
  elif [ -n "${TMUX_PANE:-}" ]; then
    printf '%s\n' "$TMUX_PANE"
  elif [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf '%s:%s\n' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"
  else
    return 1
  fi
}

DRY_RUN=0
case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=1 ;;
  -h|--help) usage; exit 0 ;;
  *) usage; exit 2 ;;
esac
[ "$#" -le 1 ] || { usage; exit 2; }

HALT=$(fm_watchdog_halt_file)
[ ! -s "$HALT" ] || fail "refusing rotation: watchdog is halted ($HALT)"
TARGET=$(resident_endpoint 2>/dev/null || true)
[ -n "$TARGET" ] || fail "refusing rotation: current resident backend endpoint is unknown"

TASK=''
HARNESS=''
BACKEND=''
FILE=''
for META in "$STATE"/*.meta; do
  [ -f "$META" ] || continue
  CANDIDATE_TASK=$(basename "$META" .meta)
  CANDIDATE_BACKEND=$(fm_backend_of_meta "$META")
  CANDIDATE_TARGET=$(fm_backend_resolve_selector "$CANDIDATE_TASK" "$STATE" 2>/dev/null || true)
  [ "$CANDIDATE_TARGET" = "$TARGET" ] || continue
  [ -z "$TASK" ] || fail "refusing rotation: multiple resident records match endpoint $TARGET"
  TASK=$CANDIDATE_TASK
  BACKEND=$CANDIDATE_BACKEND
  HARNESS=$(fm_meta_get "$META" harness)
done
[ -n "$TASK" ] || fail "refusing rotation: no live resident record matches endpoint $TARGET"
[ "$(fm_backend_agent_alive "$BACKEND" "$TARGET" 2>/dev/null || printf unknown)" = alive ] \
  || fail "refusing rotation: resident $TASK is not confidently live at $TARGET"
FILE=$(fm_watchdog_session_file "$HARNESS" "$TASK" 2>/dev/null || true)
[ -f "$FILE" ] || fail "refusing rotation: session file for resident $TASK cannot be resolved"
SID=$(fm_watchdog_session_id_from_file "$HARNESS" "$FILE" 2>/dev/null || true)
[ -n "$SID" ] || fail "refusing rotation: session id for resident $TASK cannot be resolved"
KEY=$(fm_watchdog_marker_key "$TASK")
for MARKER in "$STATE/watchdog/.clear-inflight-$KEY" "$STATE/watchdog/.compact-inflight-$KEY" "$STATE/watchdog/.resident-rotation-$KEY"; do
  [ ! -e "$MARKER" ] || fail "refusing rotation: rotation already in flight ($MARKER)"
done
HANDOFF_PLAN="$FM_HOME/fm-state/handoffs/handoff-${KEY}-<UTC>-<pid>.md"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'dry-run: predecessor task=%s sid=%s\n' "$TASK" "$SID"
  printf 'dry-run: session_file=%s\n' "$FILE"
  printf 'dry-run: backend=%s endpoint=%s\n' "$BACKEND" "$TARGET"
  printf 'dry-run: handoff=%s\n' "$HANDOFF_PLAN"
  printf 'dry-run: successor=watchdog handoff -> fm-successor.sh -> adopt worktree -> prove readiness -> retire predecessor\n'
  exit 0
fi

LOCK="$STATE/watchdog/.resident-rotation-$KEY"
mkdir -p "$(dirname "$LOCK")"
if ! mkdir "$LOCK" 2>/dev/null; then
  fail "refusing rotation: rotation already in flight ($LOCK)"
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
printf 'fm-rotate-resident: rotating task=%s sid=%s endpoint=%s\n' "$TASK" "$SID" "$TARGET"
fm_watchdog_start_successor "$TASK" manual manual_resident_rotation
