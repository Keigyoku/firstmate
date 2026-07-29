#!/usr/bin/env bash
# Primary claim-vs-evidence coaching recorder for captain-facing state claims.
#
# Companion to bin/fm-turnend-guard.sh on the primary Claude Stop-hook path.
# docs/turnend-guard.md owns the full contract.
#
# THIS IS A REMINDER, NOT A GATE. It always exits 0 and never blocks a turn.
# A Stop hook fires after the message is already written and displayed, so it
# cannot suppress anything; blocking only forces a second message, which
# DUPLICATES the unverified claim instead of preventing it. The measured
# evidence for why a gate is unachievable here is in docs/turnend-guard.md.
#
# Behavior:
#   - Scope to the main primary checkout; secondmate homes and linked child
#     worktrees remain inert.
#   - Read the turn's final assistant text from Stop payload
#     last_assistant_message (preferred) or transcript_path JSONL (fallback).
#   - If that text asserts state but carries no source receipt, no explicit
#     unverified/attribution marker, and - for rendered-app claims - no fresh
#     glass capture, record ONE coaching line for the next turn.
#   - bin/fm-claim-coach-inject.sh delivers that line at the next
#     UserPromptSubmit and clears it.
#   - Missing/ambiguous message content => record nothing.
#   - stop_hook_active=true => record nothing (at most one line per turn).
#   - config/claim-guard exactly "off" disables the check.
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
# Freshness window for fm-state/last-glass-capture (seconds). Default ~15 min.
MAX_AGE=${FM_CLAIM_GLASS_MAX_AGE:-900}

# Every exit below is 0. This hook must never block a turn.
[ "$(cat "$CONFIG/claim-guard" 2>/dev/null || true)" = off ] && exit 0

PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null) || exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

# --- scope precisely to the main PRIMARY checkout ---------------------------
[ -f "$FM_ROOT/.fm-secondmate-home" ] && exit 0
GIT_DIR=$(git -C "$FM_ROOT" rev-parse --git-dir 2>/dev/null) || exit 0
GIT_COMMON_DIR=$(git -C "$FM_ROOT" rev-parse --git-common-dir 2>/dev/null) || exit 0
[ "$GIT_DIR" = "$GIT_COMMON_DIR" ] || exit 0
[ -f "$FM_ROOT/AGENTS.md" ] || exit 0
[ -d "$FM_ROOT/bin" ] || exit 0
[ -d "$STATE" ] || exit 0

SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)

# Prefer the Stop payload's last_assistant_message; the JSONL transcript often
# still lacks the final assistant row at hook time.
LAST_TEXT=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null) || exit 0
if [ -z "$LAST_TEXT" ]; then
  TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
  [ -n "$TRANSCRIPT" ] || exit 0
  [ -f "$TRANSCRIPT" ] || exit 0
  LAST_TEXT=$(
    jq -rs '
      [
        .[]
        | select(type == "object")
        | select(.type == "assistant")
        | select((.isSidechain // false) | not)
        | .message.content as $c
        | (
            if ($c | type) == "string" then $c
            elif ($c | type) == "array" then
              ([$c[] | select(type == "object" and .type == "text") | .text // empty] | join("\n"))
            else ""
            end
          )
        | select(length > 0)
      ]
      | if length == 0 then empty else .[-1] end
    ' "$TRANSCRIPT" 2>/dev/null
  ) || exit 0
fi
[ -n "$LAST_TEXT" ] || exit 0

# --- coarse detection -------------------------------------------------------
# Deliberately coarse. Because a hit now costs one reminder line instead of a
# round trip, noticing too often is cheap. There is no clause splitting, mood
# exclusion, or quoted-span parsing here: those existed only to avoid false
# BLOCKS, and every one of them leaked evidence across its own span boundary.

# An outcome/state assertion. Bare "work" is absent: it is a noun in most prose.
message_asserts_state() {
  printf '%s' "$1" | grep -Eiq \
    '(\b(works|working|renders?|rendering|rendered|adopted|healthy|fixed|live|passed|passing|green|clean|done|landed|merged|reproduced|confirmed|verified|resolved|deployed|shipped|completed?)\b|booted clean|came up clean|\bis up\b)'
}

# Rendered application state: the only class a screenshot can evidence.
message_claims_rendered_state() {
  printf '%s' "$1" | grep -Eiq \
    '(\b(renders?|rendering|rendered|adopted)\b|booted clean|came up clean)'
}

message_asserts_non_rendered_state() {
  printf '%s' "$1" | grep -Eiq \
    '(\b(works|working|passed|passing|green|clean|done|landed|merged|reproduced|confirmed|verified|resolved|deployed|shipped|completed?|fixed|live|healthy)\b|\bis up\b)'
}

message_carries_receipt() {
  local text=$1
  printf '%s' "$text" | grep -Eiq 'https?://[^[:space:]]' && return 0
  printf '%s' "$text" | grep -Eiq '\b[[:alnum:]_./-]+\.[[:alnum:]]+:[0-9]+' && return 0
  # shellcheck disable=SC2016 # Literal backticks are the pattern, not expansion.
  printf '%s' "$text" | grep -Eq '`[^`]*[./ ][^`]*`' && return 0
  # Commit sha; require a digit so hex-looking words ("defaced") do not match.
  printf '%s' "$text" | grep -Eoi '\b[0-9a-f]{7,40}\b' | grep -q '[0-9]' && return 0
  return 1
}

message_marks_unverified() {
  printf '%s' "$1" | grep -Eiq \
    '\b(unverified|unconfirmed|unproven|not verified|have not verified|have not reproduced|has not reproduced|not reproduced|reportedly|per the crew|crew reports|reports that|claims to)\b'
}

message_asserts_state "$LAST_TEXT" || exit 0
message_carries_receipt "$LAST_TEXT" && exit 0
message_marks_unverified "$LAST_TEXT" && exit 0

# --- glass: the receipt for a rendered-state claim, and only for that --------
MARKER="$FM_HOME/fm-state/last-glass-capture"
glass_evidence_fresh() {
  local epoch _path now age
  [ -f "$MARKER" ] || return 1
  read -r epoch _path < "$MARKER" || return 1
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  now=$(date +%s)
  age=$((now - epoch))
  [ "$age" -ge 0 ] || return 1
  [ "$age" -le "$MAX_AGE" ] || return 1
  return 0
}

# --- record one coaching line for the next turn -----------------------------
# The remedy names the instrument that can actually evidence THIS kind of
# claim. A screenshot is the wrong instrument for a code, CI, or repo claim
# (data/learnings.md).
if message_claims_rendered_state "$LAST_TEXT" &&
   ! message_asserts_non_rendered_state "$LAST_TEXT"; then
  glass_evidence_fresh && exit 0
  LINE='claim-coach: last turn asserted rendered app state with no fresh glass - run bin/fm-glass.sh, read the image and cite its path, or mark the claim unverified.'
else
  LINE='claim-coach: last turn asserted state with no receipt - cite a URL, file.ext:line, a backticked command, or a commit sha, or mark the claim unverified.'
fi

PENDING_DIR="$FM_HOME/fm-state"
PENDING="$PENDING_DIR/claim-coach-pending"
mkdir -p "$PENDING_DIR" 2>/dev/null || exit 0
tmp="$PENDING.$$"
if jq -cn --arg s "$SESSION_ID" --argjson e "$(date +%s)" --arg l "$LINE" \
  '{session_id:$s, epoch:$e, line:$l}' > "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$PENDING" 2>/dev/null || rm -f "$tmp" 2>/dev/null
else
  rm -f "$tmp" 2>/dev/null
fi
exit 0
