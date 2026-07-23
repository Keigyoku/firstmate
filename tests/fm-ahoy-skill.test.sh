#!/usr/bin/env bash
# Static regression for the built-in /ahoy skill port (upstream #873 / 593e3a2).
# The full captain-translation contract suite is not on this fork; keep only the
# ahoy presence and README trigger checks that travel with the skill itself.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AHOY="$ROOT/.agents/skills/ahoy/SKILL.md"
README="$ROOT/README.md"

test_ahoy_is_an_internal_user_invocable_skill() {
  assert_present "$AHOY" "ahoy skill is missing"
  assert_grep 'name: ahoy' "$AHOY" "ahoy skill metadata has the wrong name"
  assert_grep 'user-invocable: true' "$AHOY" "ahoy skill is not user-invocable"
  assert_grep '  internal: true' "$AHOY" "ahoy skill is not internal"
  [ ! -e "$ROOT/skills/ahoy" ] || fail "ahoy must not exist in the public installer-facing skills directory"
  pass "ahoy is internal, user-invocable, and absent from public skills"
}

test_ahoy_readme_uses_cross_harness_convention() {
  assert_grep "| \`/ahoy\`" "$README" "README built-in skills table does not list /ahoy"
  assert_grep 'Recap only visible session events' "$README" "README /ahoy description is missing"
  pass "README lists /ahoy with the cross-harness convention"
}

test_ahoy_session_history_only_contract() {
  assert_grep 'session-history-only' "$AHOY" "ahoy must declare session-history-only recap branch"
  assert_grep 'Do not call Bearings, shell commands, fleet snapshots' "$AHOY" \
    "ahoy must forbid live fleet/API gathering on the recap branch"
  assert_grep '../bearings/SKILL.md' "$AHOY" "ahoy must fall back to bearings on first captain message"
  pass "ahoy owns the session-history-only contract with bearings fallback"
}

test_ahoy_is_an_internal_user_invocable_skill
test_ahoy_readme_uses_cross_harness_convention
test_ahoy_session_history_only_contract
