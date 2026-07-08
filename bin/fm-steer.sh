#!/usr/bin/env bash
# Backend-aware watchdog steer.
# Usage: fm-steer.sh <task-id-or-selector> <text>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-watchdog-lib.sh
. "$SCRIPT_DIR/fm-watchdog-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "usage: fm-steer.sh <task-id-or-selector> <text>" >&2
  exit 2
fi

SID=$1
shift
TEXT=$*
CONFIG=$(fm_watchdog_thresholds)
RETRIES=$(printf '%s' "$CONFIG" | jq -r '.steer_retries // 3')
case "$RETRIES" in ''|*[!0-9]*) RETRIES=3 ;; esac
[ "$RETRIES" -gt 0 ] || RETRIES=1
TIMEOUT_SEC=$(printf '%s' "$CONFIG" | jq -r '.steer_timeout_sec // 120')
case "$TIMEOUT_SEC" in ''|*[!0-9]*) TIMEOUT_SEC=120 ;; esac
[ "$TIMEOUT_SEC" -gt 0 ] || TIMEOUT_SEC=120

TARGET=$(fm_backend_resolve_selector "$SID" "$STATE" 2>/dev/null || printf '%s' "$SID")
BACKEND=$(fm_backend_of_selector "$SID" "$TARGET" "$STATE" 2>/dev/null || printf tmux)

deliver_once() {
  if [ -n "${FM_STEER_BACKEND_CMD:-}" ]; then
    with_timeout "$FM_STEER_BACKEND_CMD" "$BACKEND" "$TARGET" "$TEXT"
    return $?
  fi
  with_timeout env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_SEND_SETTLE="${FM_STEER_SEND_SETTLE:-0}" "$SCRIPT_DIR/fm-send.sh" "$SID" "$TEXT"
}

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SEC" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$TIMEOUT_SEC" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$TIMEOUT_SEC" "$@"
  else
    echo "fm-steer: missing timeout, gtimeout, or perl for bounded delivery" >&2
    return 124
  fi
}

attempt=1
while [ "$attempt" -le "$RETRIES" ]; do
  if deliver_once; then
    fm_watchdog_event steer "$SID" delivered "backend=$BACKEND attempts=$attempt"
    exit 0
  fi
  [ "$attempt" -lt "$RETRIES" ] && sleep "${FM_STEER_BACKOFF_SEC:-5}"
  attempt=$((attempt + 1))
done

fm_watchdog_event steer "$SID" undeliverable "backend=$BACKEND attempts=$RETRIES"
exit 4
