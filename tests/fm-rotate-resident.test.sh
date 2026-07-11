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
  local name=$1 home fakebin sessions project_key
  home="$TMP_ROOT/$name"
  fakebin="$TMP_ROOT/$name-bin"
  sessions="$TMP_ROOT/$name-sessions"
  mkdir -p "$home/state/watchdog" "$home/data/resident" "$fakebin" "$home/project"
  cat > "$home/state/resident.meta" <<EOF
window=%77
project=$home/project
worktree=$home/project
backend=tmux
harness=claude
kind=ship
EOF
  project_key=$(cd "$home/project" && pwd -P | sed 's#[^A-Za-z0-9]#-#g')
  mkdir -p "$sessions/$project_key"
  printf '{"sessionId":"resident-session"}\n' > "$sessions/$project_key/resident-session.jsonl"
  cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'claude\n'
EOF
  chmod +x "$fakebin/tmux"
  printf '%s\n%s\n%s\n' "$home" "$fakebin" "$sessions"
}

run_fixture() {
  local home=$1 fakebin=$2 sessions=$3
  shift 3
  env PATH="$fakebin:$PATH" FM_HOME="$home" FM_RESIDENT_TARGET="${FM_TEST_TARGET:-%77}" \
    FM_WATCHDOG_CLAUDE_SESSION_DIR="$sessions" "$ROOT/bin/fm-rotate-resident.sh" "$@"
}

test_resident_resolution_and_dry_run() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture dry)
  home=$(printf '%s\n' "$fixture" | sed -n '1p')
  fakebin=$(printf '%s\n' "$fixture" | sed -n '2p')
  sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  out=$(run_fixture "$home" "$fakebin" "$sessions" --dry-run)
  assert_contains "$out" 'predecessor task=resident sid=resident-session' 'dry-run did not resolve resident session'
  assert_contains "$out" 'backend=tmux endpoint=%77' 'dry-run did not resolve backend endpoint'
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
  if out=$(run_fixture "$home" "$fakebin" "$sessions" --dry-run 2>&1); then fail 'halted watchdog was accepted'; fi
  assert_contains "$out" 'watchdog is halted' 'halt refusal was unclear'
  pass 'halted watchdog is refused'
}

test_refuses_rotation_in_flight() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture inflight); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  : > "$home/state/watchdog/.clear-inflight-resident"
  if out=$(run_fixture "$home" "$fakebin" "$sessions" --dry-run 2>&1); then fail 'in-flight rotation was accepted'; fi
  assert_contains "$out" 'rotation already in flight' 'in-flight refusal was unclear'
  pass 'rotation already in flight is refused'
}

test_refuses_no_live_resident() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture missing); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  if out=$(FM_TEST_TARGET=%88 run_fixture "$home" "$fakebin" "$sessions" --dry-run 2>&1); then fail 'missing resident was accepted'; fi
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
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_RESIDENT_TARGET=%77 FM_WATCHDOG_CLAUDE_SESSION_DIR="$sessions" \
    FM_WATCHDOG_SUCCESSOR_CMD="$mock" FM_TEST_SUCCESSOR_LOG="$log" "$ROOT/bin/fm-rotate-resident.sh")
  [ "$(sed -n '1p' "$log")" = resident ] || fail 'shared successor helper received wrong predecessor'
  handoff=$(sed -n '2p' "$log")
  [ -f "$handoff" ] || fail 'shared successor helper did not create the handoff artifact'
  grep -q 'Reason: manual_resident_rotation.' "$handoff" || fail 'manual handoff reason is missing'
  assert_contains "$out" 'rotating task=resident sid=resident-session' 'rotation status omitted resolved resident'
  [ ! -e "$home/state/watchdog/.resident-rotation-resident" ] || fail 'rotation lock survived successful delegation'
  pass 'manual trigger invokes the shared watchdog handoff and successor helper'
}

test_resident_resolution_and_dry_run
test_refuses_halted_watchdog
test_refuses_rotation_in_flight
test_refuses_no_live_resident
test_invokes_shared_successor_helper
echo "PASS: $PASS tests"
