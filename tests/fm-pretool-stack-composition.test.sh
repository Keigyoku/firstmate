#!/usr/bin/env bash
# Prove primary PreToolUse guards compose rather than replace each other.
# Fork stacks: arm-pretool seatbelt + subagent guard (+ optional cd later).
# Stop path still chains turnend + claim guard.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETTINGS="$ROOT/.claude/settings.json"
[ -f "$SETTINGS" ] || fail "missing $SETTINGS"

# jq required for structured assert
command -v jq >/dev/null || fail "jq required"

bash_cmds=$(jq -r '
  .hooks.PreToolUse[]?
  | select(.matcher=="Bash")
  | .hooks[]?.command // empty
' "$SETTINGS")
assert_contains "$bash_cmds" 'fm-arm-pretool-check.sh' \
  'Bash PreToolUse must still include arm-pretool seatbelt'
assert_contains "$bash_cmds" 'fm-cd-pretool-check.sh' \
  'Bash PreToolUse must compose cd-guard with arm-pretool'

# Subagent guard uses matcher ".*" so it sees every tool name
star_cmds=$(jq -r '
  .hooks.PreToolUse[]?
  | select(.matcher==".*")
  | .hooks[]?.command // empty
' "$SETTINGS")
assert_contains "$star_cmds" 'fm-subagent-pretool-check.sh' \
  '.* PreToolUse must include subagent guard'

# Ensure arm was not removed when subagent was added
arm_count=$(printf '%s\n' "$bash_cmds" | grep -c 'fm-arm-pretool-check.sh' || true)
[ "$arm_count" -ge 1 ] || fail "arm-pretool missing after subagent composition"

# Stop path: turnend and claim guard both present (fork private claim guard)
stop_cmds=$(jq -r '.hooks.Stop[]?.hooks[]?.command // empty' "$SETTINGS")
assert_contains "$stop_cmds" 'fm-turnend-guard.sh' 'Stop must include turnend guard'
assert_contains "$stop_cmds" 'fm-claim-guard.sh' 'Stop must keep claim guard composed with turnend'

# Scripts exist and are executable
[ -x "$ROOT/bin/fm-arm-pretool-check.sh" ] || fail 'arm-pretool not executable'
[ -x "$ROOT/bin/fm-subagent-pretool-check.sh" ] || fail 'subagent-pretool not executable'

# Live stack: both checkers can run without clobbering each other when invoked
# as separate PreToolUse entries (exit codes independent).
allow_arm=$("$ROOT/bin/fm-arm-pretool-check.sh" --command 'echo safe' 2>/dev/null; echo $?)
[ "$allow_arm" = 0 ] || fail "arm-pretool should allow non-arm command (got $allow_arm)"

# Subagent on non-primary (this worktree is linked) should be inert/allow
allow_sub=$("$ROOT/bin/fm-subagent-pretool-check.sh" --tool Agent 2>/dev/null; echo $?)
[ "$allow_sub" = 0 ] || fail "subagent guard should be inert outside primary (got $allow_sub)"

pass 'primary PreToolUse stack composes arm-pretool + subagent; Stop keeps claim guard'
