#!/usr/bin/env bash
# Crew TDD pre-execution guard installed by fm-spawn.sh for ship crew agents.
# Scouts are report-only (scratch worktree) and stay outer-gate-only like
# cursor/hermes; the guard is not installed for kind=scout.
#
# Same delivery rails as bin/fm-crew-kill-guard.sh (docs/crew-kill-guard.md): one
# shared checker, per-harness PreToolUse / tool_call / tool.execute.before adapters.
# Full fleet TDD contract text lives in the ship brief (bin/fm-brief.sh); this
# guard only pins authoring-order guidance and a tunable hard gate.
#
# Temporary-until-tuned (captain lock C2-modified, 2026-07-20). Escape hatch:
#   FM_TDD_HOOK_OFF=1
#   or config/tdd-hook with exactly "off" (checked at spawn; not installed)
# Runtime FM_TDD_HOOK_OFF=1 also allows every command if the hook is still wired.
#
# Usage:
#   fm-crew-tdd-guard.sh [--claude] --command '<shell command>'
#   <PreToolUse JSON> | fm-crew-tdd-guard.sh [--claude]
#   fm-crew-tdd-guard.sh --mark-red   # after a verified RED run; enables GREEN impl
#
# Policy (v1, tunable):
#   - Always allow test-runner commands (they are how RED is obtained).
#   - Always allow when this task has a RED marker (tdd-red-seen next to this script).
#   - Deny clear production-source shell writes without a RED marker (F1 pin).
#   - Cursor/Hermes have no pre-execution hook surface; outer gates only (brief +
#     Review Crew + replay-red CI). See docs/crew-tdd-guard.md.
set -u

CLAUDE_MODE=0
COMMAND=
MARK_RED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude) CLAUDE_MODE=1; shift ;;
    --command) [ "$#" -ge 2 ] || break; COMMAND=$2; shift 2 ;;
    --mark-red) MARK_RED=1; shift ;;
    *) break ;;
  esac
done

SELF_DIR=$(cd "$(dirname "$0")" && pwd -P)
RED_MARK="$SELF_DIR/tdd-red-seen"
PIN_MARK="$SELF_DIR/tdd-pin-delivered"

# Runtime escape hatch (uniform across every wired harness).
if [ "${FM_TDD_HOOK_OFF:-}" = "1" ]; then
  exit 0
fi

if [ "$MARK_RED" -eq 1 ]; then
  printf 'red-seen by crew after verified failing run\n' > "$RED_MARK"
  exit 0
fi

RULE='Fleet TDD (temporary hook, until tuned): no production-source shell write before a verified RED. Run the failing test first, record RED evidence per the brief Test-first section, then mark RED with: '"$SELF_DIR"'/fm-crew-tdd-guard.sh --mark-red (or touch '"$RED_MARK"'). Typed exemptions stay in the brief. Disable for a hard block: FM_TDD_HOOK_OFF=1 or config/tdd-hook=off (spawn-time).'

deny() {
  local escaped
  escaped=$(printf '%s' "[crew-tdd-guard] $RULE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

allow() {
  # One-shot pin so Claude sessions see the standing order even when the brief
  # scrollback is long. Other harnesses still carry the full contract in the brief.
  if [ "$CLAUDE_MODE" -eq 1 ] && [ ! -f "$PIN_MARK" ]; then
    local pin escaped
    pin='[crew-tdd-guard] Fleet TDD standing order is active. Follow the Test-first section in your brief (F1-F4, vertical slices, typed exemptions, A1 RED evidence). Load the tdd skill (or superpowers test-driven-development) before implementing. After a verified RED run, mark with the task tdd guard --mark-red before production-source shell writes. Escape hatch: FM_TDD_HOOK_OFF=1 (temporary until tuned).'
    escaped=$(printf '%s' "$pin" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
    # additionalContext is parsed only from STDOUT on exit 0. Emit additionalContext
    # alone (no permissionDecision) so the pin never overrides the kill-guard's deny.
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"%s"}}\n' "$escaped"
    : > "$PIN_MARK"
  fi
  exit 0
}

if [ -z "$COMMAND" ]; then
  command -v jq >/dev/null 2>&1 || allow
  payload=$(cat 2>/dev/null) || allow
  [ -n "$payload" ] || allow
  COMMAND=$(printf '%s' "$payload" | jq -er '.tool_input.command // .toolInput.command // empty' 2>/dev/null) || allow
  [ -n "$COMMAND" ] || allow
fi

# Already marked RED for this task: GREEN work is allowed.
if [ -f "$RED_MARK" ]; then
  allow
fi

# Test runners and mark-red itself always pass (how RED is obtained / recorded).
case "$COMMAND" in
  *fm-crew-tdd-guard.sh*--mark-red*|*tdd-red-seen*) allow ;;
  *cargo\ test*|*go\ test*) allow ;;
  *pytest*|*vitest*|*node\ --test*) allow ;;
  *bash\ tests/*|*/tests/*.test.sh*) allow ;;
  *npm\ test*|*npm\ run\ test*) allow ;;
esac

# Narrow production-write patterns without a RED marker (tunable; escape hatch above).
# Test-path writes are allowed so the RED test itself can be authored.
is_test_path() {
  local p=$1
  # Path-boundary matches only, so production files whose names merely contain
  # "test"/"spec" (latest.rs, inspector.rs, respec.rs) are NOT exempted.
  case "$p" in
    tests/*|*/tests/*) return 0 ;;
    __tests__/*|*/__tests__/*) return 0 ;;
    *.test.*|*.spec.*) return 0 ;;
    *_test.*|*_spec.*) return 0 ;;
    Test*|*/Test*) return 0 ;;
  esac
  return 1
}

# sed -i on a non-test path
if printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:];|&])sed[[:space:]]+(-[^[:space:]]*i[^[:space:]]*|[[:space:]]-i)'; then
  # Extract a plausible path token; if any non-test path appears after sed, deny.
  for tok in $COMMAND; do
    case "$tok" in
      -*|sed|g|'' ) continue ;;
      *.*)
        if ! is_test_path "$tok"; then
          deny
        fi
        ;;
    esac
  done
fi

# cat/tee redirects to a non-test source-looking path
if printf '%s' "$COMMAND" | grep -Eq '>|>>'; then
  # shellcheck disable=SC2086 # intentional word split of command for coarse path scan
  set -- $COMMAND
  prev=
  for tok in "$@"; do
    case "$tok" in
      '>'|'>>')
        prev=$tok
        continue
        ;;
    esac
    if [ "$prev" = '>' ] || [ "$prev" = '>>' ]; then
      case "$tok" in
        /dev/*|*.md|*.txt|*.log|*.jsonl) ;;
        *)
          if ! is_test_path "$tok"; then
            case "$tok" in
              *.rs|*.go|*.ts|*.tsx|*.js|*.jsx|*.py|*.sh|*/src/*|*/bin/*|*/lib/*|*/crates/*)
                deny
                ;;
            esac
          fi
          ;;
      esac
    fi
    prev=$tok
  done
fi

allow
