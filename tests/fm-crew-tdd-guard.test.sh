#!/usr/bin/env bash
# Behavior tests for bin/fm-crew-tdd-guard.sh and its spawn wiring.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-crew-tdd-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-tdd-guard)
TASK_TMP="$TMP_ROOT/task"
mkdir -p "$TASK_TMP"
install -m 0700 "$CHECK" "$TASK_TMP/fm-crew-tdd-guard.sh"
GUARD="$TASK_TMP/fm-crew-tdd-guard.sh"

expect_allow() {
  local cmd=$1 status
  "$GUARD" --command "$cmd" >/dev/null 2>"$TMP_ROOT/allow.err"
  status=$?
  expect_code 0 "$status" "expected allow for: $cmd"
}

expect_deny() {
  local cmd=$1 status
  "$GUARD" --command "$cmd" >/dev/null 2>"$TMP_ROOT/deny.err"
  status=$?
  expect_code 2 "$status" "expected deny for: $cmd"
  assert_grep 'crew-tdd-guard' "$TMP_ROOT/deny.err" "deny missing tdd-guard label for: $cmd"
}

# Runtime hatch always allows.
FM_TDD_HOOK_OFF=1 expect_allow 'cat > src/foo.rs <<EOF
x
EOF'
unset FM_TDD_HOOK_OFF

# Test runners always allow (how RED is obtained).
expect_allow 'bash tests/fm-brief.test.sh'
expect_allow 'cargo test -p vellum-core foo'
expect_allow 'node --test dashboard/tests/x.test.mjs'
expect_allow 'npx vitest run path/to/file.test.jsx'

# Production-source shell write without RED marker is denied.
expect_deny 'cat > src/lib/foo.rs <<EOF
pub fn x() {}
EOF'
expect_deny 'sed -i s/a/b/ bin/fm-spawn.sh'

# After --mark-red, production writes allow.
"$GUARD" --mark-red
assert_present "$TASK_TMP/tdd-red-seen" "mark-red did not create tdd-red-seen"
expect_allow 'cat > src/lib/foo.rs <<EOF
pub fn x() {}
EOF'
pass 'tdd guard: hatch, test runners, deny without RED, allow after mark-red'

# Test-path writes allow even without marker (author the RED test).
rm -f "$TASK_TMP/tdd-red-seen" "$TASK_TMP/tdd-pin-delivered"
expect_allow 'cat > tests/fm-new.test.sh <<EOF
true
EOF'
expect_allow 'cat > src/foo.test.ts <<EOF
test
EOF'
pass 'tdd guard: test-path writes allowed without RED marker'

# Claude transport deny shape matches kill-guard (empty stdout on deny).
rm -f "$TASK_TMP/tdd-red-seen"
claude_out=$(printf '%s\n' '{"tool_input":{"command":"cat > src/x.rs"}}' | "$GUARD" --claude 2>"$TMP_ROOT/claude.err")
claude_status=$?
expect_code 2 "$claude_status" 'Claude transport did not deny production write'
[ -z "$claude_out" ] || fail 'Claude deny wrote stdout; Claude Code would ignore it'
assert_grep 'permissionDecision":"deny' "$TMP_ROOT/claude.err" 'Claude deny object missing'
pass 'tdd guard: Claude transport denies with empty stdout'

# Structural spawn wiring: TDD second-guard on the same rails as kill-guard.
spawn=$(cat "$ROOT/bin/fm-spawn.sh")
for needle in \
  'fm-crew-tdd-guard.sh' \
  'TDD_HOOK' \
  'FM_TDD_HOOK_OFF' \
  'config/tdd-hook' \
  'fm-tdd-guard.d' \
  '.fm-grok-tddguard' \
  'crew tdd guard denied'; do
  assert_contains "$spawn" "$needle" "spawn wiring missing: $needle"
done
# Cursor/hermes comments must document outer-gate-only TDD.
assert_contains "$spawn" 'outer-gate-only' 'spawn missing outer-gate-only note for hookless adapters'
# Codex dual-hook string includes TDD_GUARD when hatch is open.
assert_contains "$spawn" 'command=\"$TDD_GUARD\"' 'codex PreToolUse must include TDD_GUARD when enabled'
pass 'spawn structurally wires TDD second-guard on kill-guard rails'

# Teardown cleans grok tdd pointer/token.
teardown=$(cat "$ROOT/bin/fm-teardown.sh")
assert_contains "$teardown" 'remove_grok_tddguard_auth' 'teardown missing tddguard auth removal'
assert_contains "$teardown" '.fm-grok-tddguard' 'teardown missing worktree tddguard pointer cleanup'
assert_contains "$teardown" 'grok-tddguard-token' 'teardown missing tddguard token cleanup'
pass 'teardown cleans grok TDD guard artifacts'

# Docs own outer-gate-only for cursor/hermes.
assert_grep 'Cursor and Hermes' "$ROOT/docs/crew-tdd-guard.md" 'crew-tdd-guard.md missing cursor/hermes section'
assert_grep 'outer-gate-only' "$ROOT/docs/crew-tdd-guard.md" 'crew-tdd-guard.md missing outer-gate-only wording'
assert_grep 'crew-tdd-guard' "$ROOT/docs/crew-kill-guard.md" 'kill-guard.md should point at tdd-guard'
pass 'docs record multi-harness TDD rails and outer-gate-only adapters'
