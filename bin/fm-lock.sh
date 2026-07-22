#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
#
# FM_LOCK_PID=<pid>  (optional) skip ancestry walk and use this PID as the lock
# holder. Used by fm-resident-start.sh --launch: setup+publish runs under the
# start process, then exec replaces that image with the harness under the same
# PID so state/.lock and resident-current stay honest without a leftover shell.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
# cursor matches cursor-agent's basename; hermes matches its own.
HARNESS_RE='claude|codex|opencode|grok|cursor|hermes|^pi$'

harness_pid() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

if [ -n "${FM_LOCK_PID:-}" ]; then
  case "$FM_LOCK_PID" in
    ''|*[!0-9]*)
      echo "error: FM_LOCK_PID must be a positive integer process id" >&2
      exit 1
      ;;
  esac
  if ! [ "$FM_LOCK_PID" -gt 0 ] 2>/dev/null; then
    echo "error: FM_LOCK_PID must be a positive integer process id" >&2
    exit 1
  fi
  kill -0 "$FM_LOCK_PID" 2>/dev/null || {
    echo "error: FM_LOCK_PID $FM_LOCK_PID is not a live process" >&2
    exit 1
  }
  me=$FM_LOCK_PID
else
  me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
fi
lock_existed=0
previous_lock=
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
  lock_existed=1
  previous_lock=$old
fi
echo "$me" > "$LOCK"
rollback_lock() {
  current=$(cat "$LOCK" 2>/dev/null || true)
  [ "$current" = "$me" ] || return 0
  if [ "$lock_existed" -eq 1 ]; then
    printf '%s\n' "$previous_lock" > "$LOCK"
  else
    rm -f "$LOCK"
  fi
}
if ! FM_RESIDENT_PID="$me" "$SCRIPT_DIR/fm-resident-setup.sh" >/dev/null; then
  rollback_lock
  exit 1
fi
if ! FM_RESIDENT_PID="$me" "$SCRIPT_DIR/fm-resident-publish.sh" ready; then
  rollback_lock
  exit 1
fi
echo "lock acquired: harness pid $me"
