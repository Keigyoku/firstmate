#!/usr/bin/env bash
# Primary claim-vs-evidence guard for captain-facing daily-driver app state.
#
# Companion to bin/fm-turnend-guard.sh on the primary Claude Stop-hook path.
# Prose rules in data/captain.md failed repeatedly; this is the mechanical
# enforcement layer. docs/turnend-guard.md owns the full contract.
#
# Behavior:
#   - Scope to the main primary checkout; secondmate homes and linked child
#     worktrees remain inert.
#   - Read the turn's final assistant text from Stop payload
#     last_assistant_message (preferred) or transcript_path JSONL (fallback).
#   - If that text asserts captain-facing app state AND no fresh glass capture
#     marker exists, exit 2 with a remedy on stderr (Claude/Codex block).
#   - Missing/ambiguous message content => fail open (exit 0).
#   - stop_hook_active=true => allow (at most one block per turn).
#   - config/claim-guard exactly "off" disables the guard.
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

[ "$(cat "$CONFIG/claim-guard" 2>/dev/null || true)" = off ] && exit 0

# Read the whole Stop payload once; never block on unreadable/absent stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is required to read stop_hook_active and transcript_path safely.
# Missing jq => fail open (same posture as fm-turnend-guard.sh).
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
# state/ may be empty but should exist on a real primary; fail open if not.
[ -d "$STATE" ] || exit 0

# Prefer the Stop payload's last_assistant_message. Claude Code 2.1.x supplies
# it on every Stop event; the JSONL transcript often still lacks the final
# assistant row at hook time (observed 2026-07-20: assistant_types=0 in the
# transcript while last_assistant_message held the claim text). Fall back to
# transcript_path JSONL only when the payload field is absent/empty.
LAST_TEXT=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null) || exit 0
if [ -z "$LAST_TEXT" ]; then
  TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null) || exit 0
  # Missing/empty transcript path => fail open (cannot judge the claim safely).
  [ -n "$TRANSCRIPT" ] || exit 0
  [ -f "$TRANSCRIPT" ] || exit 0
  # Extract the last non-sidechain assistant text from the JSONL transcript.
  # Claude stores content as a list of blocks; only type=="text" is spoken prose.
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
# Ambiguous/empty extraction => fail open.
[ -n "$LAST_TEXT" ] || exit 0

# --- claim heuristic (conservative) -----------------------------------------
# Fire only when BOTH classes appear in the final assistant text:
#   1) App referent: vellum | daily-driver | daily driver | "the app" |
#      dashboard | glass | resident
#   2) Health/state assertion: work(s|ing) | render(s|ing|ed) | adopted |
#      "booted clean" | "came up clean" | "is up" | healthy | fixed | live
# Rationale: captain-facing app-state claims are the failure mode; pure fleet
# status ("crew is working") or pure referent mentions ("open the dashboard")
# must not block. Word boundaries keep "hourglass"/"workflow" out.
# Case-insensitive; phrase alternatives for multi-word assertions.
message_is_app_state_claim() {
  local text=$1
  printf '%s' "$text" | grep -Eiq \
    '\b(vellum|daily[ -]driver|the app|dashboard|glass|resident)\b' || return 1
  printf '%s' "$text" | grep -Eiq \
    '(\b(works?|working|renders?|rendering|rendered|adopted|healthy|fixed|live)\b|booted clean|came up clean|\bis up\b)' || return 1
  return 0
}

message_is_app_state_claim "$LAST_TEXT" || exit 0

# --- evidence: fresh glass capture marker -----------------------------------
MARKER="$FM_HOME/fm-state/last-glass-capture"
glass_evidence_fresh() {
  local epoch _path now age
  [ -f "$MARKER" ] || return 1
  # Format written by bin/fm-glass.sh: "epoch path"
  # Path field is advisory; presence of a fresh epoch is the gate.
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

if glass_evidence_fresh; then
  exit 0
fi

# Block: claim without fresh glass evidence.
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$rule"
  printf '●  TURN WOULD END WITH AN UNVERIFIED APP-STATE CLAIM\n'
  printf '●  Captain-facing render/working/adopted state requires same-turn glass evidence.\n'
  printf '●  Remedy: run bin/fm-glass.sh, read the image, cite the path, then resend the claim.\n'
  printf '●  Freshness marker: %s (max age %ss; set FM_CLAIM_GLASS_MAX_AGE to tune).\n' \
    "$MARKER" "$MAX_AGE"
  printf '●%s\n' "$rule"
} >&2
exit 2
