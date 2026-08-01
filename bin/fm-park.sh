#!/usr/bin/env bash
# Write or clear the firstmate-owned deliberate-hold marker for a crew.
#
# Parked is a representable state: one marker, one writer. The watcher and
# away-mode daemon absorb idle-pane wedge noise while this marker is present,
# recheck on the marker's cadence, and never require secondary run-step or
# status-verb corroboration for that absorb decision. Captain-relevant status
# signals still wake through the normal signal path regardless of the marker.
#
# Usage:
#   fm-park.sh <task-id> [--reason <text>] [--recheck <secs>] [--until <epoch>]
#   fm-park.sh --clear <task-id>
#
# Marker path: state/<id>.parked (JSON). Schema and absorb ownership live in
# docs/architecture.md (Event-driven supervision) and bin/fm-classify-lib.sh.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-park: %s\n' "$*" >&2
  exit 1
}

validate_id() {
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) fail "task id must be a non-empty privacy-safe slug: ${1:-}" ;;
  esac
}

CLEAR=0
ID=
REASON='deliberate hold'
RECHECK=
UNTIL=
POSITIONAL=()

while [ $# -gt 0 ]; do
  case "$1" in
    --clear)
      CLEAR=1
      shift
      ;;
    --reason)
      [ $# -ge 2 ] || fail "--reason requires a value"
      REASON=$2
      shift 2
      ;;
    --recheck)
      [ $# -ge 2 ] || fail "--recheck requires a value"
      RECHECK=$2
      shift 2
      ;;
    --until)
      [ $# -ge 2 ] || fail "--until requires a value"
      UNTIL=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do POSITIONAL+=("$1"); shift; done
      break
      ;;
    -*)
      fail "unknown option: $1"
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

if [ "$CLEAR" -eq 1 ]; then
  [ "${#POSITIONAL[@]}" -eq 1 ] || fail "usage: fm-park.sh --clear <task-id>"
  ID=${POSITIONAL[0]}
  validate_id "$ID"
  if [ ! -f "$STATE/$ID.meta" ] && [ ! -e "$(parked_marker "$ID")" ]; then
    fail "no meta or park marker for task $ID at $STATE"
  fi
  park_clear "$ID"
  exit 0
fi

[ "${#POSITIONAL[@]}" -eq 1 ] || { usage >&2; exit 2; }
ID=${POSITIONAL[0]}
validate_id "$ID"

if [ ! -f "$STATE/$ID.meta" ]; then
  fail "no meta for task $ID at $STATE/$ID.meta"
fi

case "$REASON" in
  *$'\n'*|*$'\r'*) fail "--reason must be one line" ;;
  '') fail "--reason must not be empty" ;;
esac

if [ -n "$RECHECK" ]; then
  case "$RECHECK" in
    ''|*[!0-9]*) fail "--recheck must be a non-negative integer seconds" ;;
  esac
fi

if [ -n "$UNTIL" ]; then
  case "$UNTIL" in
    ''|*[!0-9]*) fail "--until must be a unix epoch integer" ;;
  esac
fi

if [ -z "$RECHECK" ]; then
  RECHECK=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}
fi

park_write "$ID" "$REASON" "$RECHECK" "$UNTIL"
printf 'parked %s reason=%s recheck_secs=%s\n' "$ID" "$REASON" "$RECHECK"
