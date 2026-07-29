#!/usr/bin/env bash
# Deliver the claim-coach reminder recorded by bin/fm-claim-guard.sh.
#
# UserPromptSubmit hook on the primary Claude path. docs/turnend-guard.md owns
# the contract.
#
# Why this exists as a SEPARATE hook: a Stop hook's output never reaches the
# model. Measured on Claude Code (see docs/turnend-guard.md "Why a gate is not
# achievable at this hook point"): Stop stdout/stderr on exit 0 land only in
# transcript hook_success rows, never in hook_additional_context, and a resumed
# session reports seeing neither. UserPromptSubmit stdout on exit 0 IS injected
# into model context. So the guard RECORDS at turn end and this hook DELIVERS
# at the start of the next turn, which is the first moment the primary can
# actually read and act on it.
#
# Behavior:
#   - Always exits 0 and prints at most ONE line. Never blocks a prompt.
#   - Scope to the main primary checkout before inspecting pending state.
#   - Delivers the pending line only when both session ids are non-empty and
#     equal and the record is still fresh, then clears it.
#   - A pending record that is foreign-session or expired is DISCARDED, never
#     shown. A reminder about a claim nobody remembers is worse than none: it
#     teaches the reader to ignore the channel.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT=${FM_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-}}
if [ -z "$FM_ROOT" ]; then
  PWD_ROOT=$(pwd -P 2>/dev/null || true)
  if [ -f "$PWD_ROOT/AGENTS.md" ] && [ -f "$PWD_ROOT/bin/fm-claim-guard.sh" ]; then
    FM_ROOT=$PWD_ROOT
  else
    FM_ROOT=$SCRIPT_ROOT
  fi
fi
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# How long a recorded reminder stays deliverable (seconds). Default 30 min.
COACH_MAX_AGE=${FM_CLAIM_COACH_MAX_AGE:-1800}

PENDING="$FM_HOME/fm-state/claim-coach-pending"

[ "$(cat "$CONFIG/claim-guard" 2>/dev/null || true)" = off ] && exit 0

[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

[ -f "$PENDING" ] || exit 0

PAYLOAD=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0

# Any record we look at is consumed: delivered or discarded, never left to rot.
RECORD=$(cat "$PENDING" 2>/dev/null || true)
rm -f "$PENDING" 2>/dev/null || true
[ -n "$RECORD" ] || exit 0

REC_SESSION=$(printf '%s' "$RECORD" | jq -r '.session_id // empty' 2>/dev/null) || exit 0
REC_EPOCH=$(printf '%s' "$RECORD" | jq -r '.epoch // empty' 2>/dev/null) || exit 0
REC_LINE=$(printf '%s' "$RECORD" | jq -r '.line // empty' 2>/dev/null) || exit 0
[ -n "$REC_LINE" ] || exit 0

# Session scoping: a reminder from another session never surfaces here. A
# different or newly resumed session cannot inherit a stale nudge.
CUR_SESSION=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$REC_SESSION" ] || exit 0
[ -n "$CUR_SESSION" ] || exit 0
[ "$REC_SESSION" = "$CUR_SESSION" ] || exit 0

# Expiry: covers the same session resumed much later, where the session id
# still matches but the claim is long out of view.
case "$REC_EPOCH" in
  ''|*[!0-9]*) exit 0 ;;
esac
NOW=$(date +%s)
AGE=$((NOW - REC_EPOCH))
[ "$AGE" -ge 0 ] || exit 0
[ "$AGE" -le "$COACH_MAX_AGE" ] || exit 0

printf '%s\n' "$REC_LINE"
exit 0
