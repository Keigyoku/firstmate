#!/usr/bin/env bash
# Behavior tests for the manual resident rotation entry point.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-rotate-resident.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok $((PASS += 1)) - $*"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3: missing '$2' in '$1'" ;; esac; }

make_fixture() {
  local name=$1 harness=${2:-claude} home fakebin sessions project_key command
  home="$TMP_ROOT/$name"
  fakebin="$TMP_ROOT/$name-bin"
  sessions="$TMP_ROOT/$name-sessions"
  mkdir -p "$home/state/watchdog" "$home/data/resident" "$fakebin" "$home/project"
  command=$harness
  cat > "$home/state/resident.meta" <<EOF
window=session:fm-resident
project=$home/project
worktree=$home/project
backend=tmux
harness=$harness
kind=ship
EOF
  project_key=$(cd "$home/project" && pwd -P | sed 's#[^A-Za-z0-9]#-#g')
  if [ "$harness" = claude ]; then
    mkdir -p "$sessions/$project_key"
    printf '{"sessionId":"resident-session"}\n' > "$sessions/$project_key/resident-session.jsonl"
  else
    mkdir -p "$sessions"
    printf '{"type":"session_meta","payload":{"id":"resident-session","cwd":"%s"}}\n' "$home/project" > "$sessions/rollout-resident.jsonl"
  fi
  cat > "$fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\$1|\${*: -1}" = 'display-message|#{pane_current_command}' ]; then
  if [ -n "\${FM_TEST_EXPECT_LOCK_FILE:-}" ] && [ ! -d "\$FM_TEST_EXPECT_LOCK_FILE" ]; then
    printf 'missing rotation lock before liveness lookup\n' > "\$FM_TEST_LOCK_LOG"
  fi
  printf '$command\n'
  exit 0
fi
case "\$1|\${*: -1}" in
  'display-message|#{session_name}:#{window_name}') printf 'session:fm-resident\n' ;;
  *) printf '$command\n' ;;
esac
EOF
  chmod +x "$fakebin/tmux"
  printf '%s\n%s\n%s\n' "$home" "$fakebin" "$sessions"
}

run_fixture() {
  local home=$1 fakebin=$2 sessions=$3 harness=${4:-claude}
  shift 4
  if [ -n "${FM_TEST_TARGET:-}" ]; then
    env PATH="$fakebin:$PATH" FM_HOME="$home" FM_RESIDENT_TARGET="$FM_TEST_TARGET" \
      FM_WATCHDOG_CLAUDE_SESSION_DIR="$sessions" FM_WATCHDOG_CODEX_SESSION_DIR="$sessions" "$ROOT/bin/fm-rotate-resident.sh" "$@"
  else
    env PATH="$fakebin:$PATH" FM_HOME="$home" TMUX=/tmp/tmux-test TMUX_PANE=%77 \
      FM_WATCHDOG_CLAUDE_SESSION_DIR="$sessions" FM_WATCHDOG_CODEX_SESSION_DIR="$sessions" "$ROOT/bin/fm-rotate-resident.sh" "$@"
  fi
}

test_resident_resolution_and_dry_run() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture dry)
  home=$(printf '%s\n' "$fixture" | sed -n '1p')
  fakebin=$(printf '%s\n' "$fixture" | sed -n '2p')
  sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  out=$(run_fixture "$home" "$fakebin" "$sessions" claude --dry-run)
  assert_contains "$out" 'predecessor task=resident sid=resident-session' 'dry-run did not resolve resident session'
  assert_contains "$out" 'backend=tmux endpoint=session:fm-resident' 'dry-run did not resolve backend endpoint'
  assert_contains "$out" 'handoff=' 'dry-run omitted handoff plan'
  assert_contains "$out" 'fm-successor.sh' 'dry-run omitted successor plan'
  [ ! -e "$home/fm-state" ] || fail 'dry-run mutated fm-state'
  pass 'resident resolution and dry-run report are complete and non-mutating'
}

test_refuses_halted_watchdog() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture halted); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  mkdir -p "$home/fm-state"
  printf 'reason=test\n' > "$home/fm-state/watchdog.halt"
  if out=$(run_fixture "$home" "$fakebin" "$sessions" claude --dry-run 2>&1); then fail 'halted watchdog was accepted'; fi
  assert_contains "$out" 'watchdog is halted' 'halt refusal was unclear'
  pass 'halted watchdog is refused'
}

test_refuses_rotation_in_flight() {
  local marker fixture home fakebin sessions out
  for marker in .clear-steering-resident .compact-steering-resident .clear-pending-resident .compact-pending-resident; do
    fixture=$(make_fixture "inflight-$marker"); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
    : > "$home/state/watchdog/$marker"
    if out=$(run_fixture "$home" "$fakebin" "$sessions" claude --dry-run 2>&1); then fail "in-flight rotation was accepted for $marker"; fi
    assert_contains "$out" 'rotation already in flight' "in-flight refusal was unclear for $marker"
  done
  pass 'rotation already in flight is refused'
}

test_refuses_no_live_resident() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture missing); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  if out=$(FM_TEST_TARGET=%88 run_fixture "$home" "$fakebin" "$sessions" claude --dry-run 2>&1); then fail 'missing resident was accepted'; fi
  assert_contains "$out" 'no live resident record' 'missing-resident refusal was unclear'
  pass 'no live resident is refused'
}

test_invokes_shared_successor_helper() {
  local fixture home fakebin sessions mock log out handoff
  fixture=$(make_fixture successor); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  mock="$TMP_ROOT/successor-mock"
  log="$TMP_ROOT/successor.log"
  cat > "$mock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$1" "$2" > "$FM_TEST_SUCCESSOR_LOG"
EOF
  chmod +x "$mock"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_RESIDENT_TARGET=session:fm-resident FM_WATCHDOG_CLAUDE_SESSION_DIR="$sessions" \
    FM_WATCHDOG_SUCCESSOR_CMD="$mock" FM_TEST_SUCCESSOR_LOG="$log" "$ROOT/bin/fm-rotate-resident.sh")
  [ "$(sed -n '1p' "$log")" = resident ] || fail 'shared successor helper received wrong predecessor'
  handoff=$(sed -n '2p' "$log")
  [ -f "$handoff" ] || fail 'shared successor helper did not create the handoff artifact'
  grep -q 'Reason: manual_resident_rotation.' "$handoff" || fail 'manual handoff reason is missing'
  assert_contains "$out" 'rotating task=resident sid=resident-session' 'rotation status omitted resolved resident'
  [ ! -e "$home/state/watchdog/.resident-rotation-resident" ] || fail 'rotation lock survived successful delegation'
  pass 'manual trigger invokes the shared watchdog handoff and successor helper'
}

test_mutating_rotation_locks_before_liveness_lookup() {
  local fixture home fakebin sessions mock log lock_log
  fixture=$(make_fixture early-lock); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  mock="$TMP_ROOT/early-lock-successor"
  log="$TMP_ROOT/early-lock-successor.log"
  lock_log="$TMP_ROOT/early-lock.log"
  cat > "$mock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$1" "$2" > "$FM_TEST_SUCCESSOR_LOG"
EOF
  chmod +x "$mock"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_RESIDENT_TARGET=session:fm-resident FM_WATCHDOG_CLAUDE_SESSION_DIR="$sessions" \
    FM_WATCHDOG_SUCCESSOR_CMD="$mock" FM_TEST_SUCCESSOR_LOG="$log" \
    FM_TEST_EXPECT_LOCK_FILE="$home/state/watchdog/.resident-rotation-resident" FM_TEST_LOCK_LOG="$lock_log" \
    "$ROOT/bin/fm-rotate-resident.sh" >/dev/null
  [ ! -s "$lock_log" ] || fail "$(cat "$lock_log")"
  pass 'mutating rotation claims the resident before liveness lookup'
}

test_refuses_unsupported_resident_kind() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture unsupported); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$home/state/resident.meta"
  if out=$(run_fixture "$home" "$fakebin" "$sessions" claude 2>&1); then fail 'unsupported resident kind was accepted'; fi
  assert_contains "$out" 'unsupported kind secondmate' 'unsupported-kind refusal was unclear'
  [ ! -e "$home/fm-state" ] || fail 'unsupported kind created handoff state'
  pass 'unsupported resident kinds are refused before handoff creation'
}

test_codex_dry_run_does_not_write_rollout_cache() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture codex-dry codex)
  home=$(printf '%s\n' "$fixture" | sed -n '1p')
  fakebin=$(printf '%s\n' "$fixture" | sed -n '2p')
  sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  out=$(run_fixture "$home" "$fakebin" "$sessions" codex --dry-run)
  assert_contains "$out" 'predecessor task=resident sid=resident-session' 'codex dry-run did not resolve session'
  [ ! -e "$home/state/watchdog/.codex-rollout-resident" ] || fail 'codex dry-run wrote rollout cache'
  [ ! -e "$home/fm-state" ] || fail 'codex dry-run mutated fm-state'
  pass 'codex dry-run does not write rollout cache'
}

test_resident_resolution_and_dry_run
test_refuses_halted_watchdog
test_refuses_rotation_in_flight
test_refuses_no_live_resident
test_invokes_shared_successor_helper
test_mutating_rotation_locks_before_liveness_lookup
test_refuses_unsupported_resident_kind
test_codex_dry_run_does_not_write_rollout_cache
echo "PASS: $PASS tests"
