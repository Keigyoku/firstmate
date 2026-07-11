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
stat_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1"
  else
    stat -c %Y "$1"
  fi
}
path_snapshot() {
  local root=$1 item type mtime sum
  find "$root" -print | LC_ALL=C sort | while IFS= read -r item; do
    if [ -d "$item" ]; then
      type=d
      sum=-
    else
      type=f
      sum=$(cksum "$item")
    fi
    mtime=$(stat_mtime "$item")
    printf '%s\t%s\t%s\t%s\n' "$item" "$type" "$mtime" "$sum"
  done
}

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

test_refuses_live_resident_rotation_claim() {
  local fixture home fakebin sessions out lock
  fixture=$(make_fixture live-claim); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  printf 'manual\n' > "$lock/owner"
  if out=$(run_fixture "$home" "$fakebin" "$sessions" claude 2>&1); then fail 'live resident rotation claim was accepted'; fi
  assert_contains "$out" 'rotation already in flight' 'live-claim refusal was unclear'
  pass 'live resident rotation claim is refused'
}

test_dry_run_allows_stale_initialized_claim_readonly() {
  local fixture home fakebin sessions out lock before after
  fixture=$(make_fixture stale-claim-dry); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir "$lock"
  printf '999999999\n' > "$lock/pid"
  printf 'manual\n' > "$lock/owner"
  printf 'stale-token\n' > "$lock/token"
  printf '2000-01-01T00:00:00Z\n' > "$lock/created_at"
  before=$(path_snapshot "$lock")
  out=$(run_fixture "$home" "$fakebin" "$sessions" claude --dry-run)
  after=$(path_snapshot "$lock")
  assert_contains "$out" 'predecessor task=resident sid=resident-session' 'stale initialized claim blocked dry-run'
  [ "$before" = "$after" ] || fail 'dry-run mutated stale initialized claim'
  pass 'dry-run treats stale initialized claims as inactive without writes'
}

test_dry_run_refuses_live_initialized_claim_readonly() {
  local fixture home fakebin sessions out lock before after
  fixture=$(make_fixture live-claim-dry); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  printf 'manual\n' > "$lock/owner"
  printf 'live-token\n' > "$lock/token"
  printf '2026-01-01T00:00:00Z\n' > "$lock/created_at"
  before=$(path_snapshot "$lock")
  if out=$(run_fixture "$home" "$fakebin" "$sessions" claude --dry-run 2>&1); then fail 'live initialized dry-run claim was accepted'; fi
  after=$(path_snapshot "$lock")
  assert_contains "$out" 'rotation already in flight' 'live initialized dry-run refusal was unclear'
  [ "$before" = "$after" ] || fail 'dry-run mutated live initialized claim'
  pass 'dry-run refuses live initialized claims without writes'
}

test_dry_run_refuses_fresh_provisional_claim_readonly() {
  local fixture home fakebin sessions out lock before after
  fixture=$(make_fixture provisional-claim-dry); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir "$lock"
  before=$(path_snapshot "$lock")
  if out=$(run_fixture "$home" "$fakebin" "$sessions" claude --dry-run 2>&1); then fail 'fresh provisional dry-run claim was accepted'; fi
  after=$(path_snapshot "$lock")
  assert_contains "$out" 'rotation already in flight' 'fresh provisional dry-run refusal was unclear'
  [ "$before" = "$after" ] || fail 'dry-run mutated fresh provisional claim'
  pass 'dry-run refuses fresh provisional claims without writes'
}

test_recovers_stale_resident_rotation_claim() {
  local fixture home fakebin sessions mock log lock
  fixture=$(make_fixture stale-claim); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir "$lock"
  printf '999999999\n' > "$lock/pid"
  printf 'stale\n' > "$lock/owner"
  mock="$TMP_ROOT/stale-claim-successor"
  log="$TMP_ROOT/stale-claim-successor.log"
  cat > "$mock" <<'EOF'
#!/usr/bin/env bash
printf '%s\n%s\n' "$1" "$2" > "$FM_TEST_SUCCESSOR_LOG"
EOF
  chmod +x "$mock"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_RESIDENT_TARGET=session:fm-resident FM_WATCHDOG_CLAUDE_SESSION_DIR="$sessions" \
    FM_WATCHDOG_SUCCESSOR_CMD="$mock" FM_TEST_SUCCESSOR_LOG="$log" "$ROOT/bin/fm-rotate-resident.sh" >/dev/null
  [ "$(sed -n '1p' "$log")" = resident ] || fail 'stale claim recovery did not delegate successor'
  [ ! -e "$lock" ] || fail 'stale resident rotation claim survived successful delegation'
  pass 'stale resident rotation claim is recovered'
}

test_rotation_claim_token_fences_reacquired_lock() {
  local home claim1 claim2 lock pid_after
  home="$TMP_ROOT/token-fence-home"
  mkdir -p "$home/state/watchdog"
  claim1=$(FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_claim resident manual' _ "$ROOT/bin/fm-watchdog-lib.sh")
  FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_release resident "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$claim1"
  claim2=$(FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_claim resident watchdog' _ "$ROOT/bin/fm-watchdog-lib.sh")
  lock="$home/state/watchdog/.resident-rotation-resident"
  if FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_set_pid resident 999999 "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$claim1"; then
    fail 'stale rotation claim token rewrote replacement pid'
  fi
  pid_after=$(sed -n '1p' "$lock/pid")
  [ "$pid_after" != 999999 ] || fail 'replacement rotation pid was corrupted by stale token'
  if FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_release resident "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$claim1"; then
    fail 'stale rotation claim token released replacement lock'
  fi
  [ -d "$lock" ] || fail 'replacement rotation lock was removed by stale token'
  FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_release resident "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$claim2"
  [ ! -e "$lock" ] || fail 'current rotation claim did not release its own lock'
  pass 'rotation claim token fences replacement lock mutations'
}

test_provisional_rotation_claim_blocks_contenders() {
  local home lock out
  home="$TMP_ROOT/provisional-claim-home"
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir -p "$home/state/watchdog"
  mkdir "$lock"
  if FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_claim resident watchdog' _ "$ROOT/bin/fm-watchdog-lib.sh" >/dev/null; then
    fail 'pid-less provisional rotation claim was replaced immediately'
  fi
  if ! FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_active resident' _ "$ROOT/bin/fm-watchdog-lib.sh"; then
    fail 'pid-less provisional rotation claim was not treated as active'
  fi
  [ -d "$lock" ] || fail 'pid-less provisional rotation claim was removed before stale age'
  out=$(find "$lock" -mindepth 1 -maxdepth 1 -print)
  [ -z "$out" ] || fail 'provisional rotation claim should not be initialized by a contender'
  pass 'pid-less provisional rotation claim blocks contenders'
}

test_abandoned_provisional_rotation_claim_is_recovered() {
  local home lock claim
  home="$TMP_ROOT/abandoned-provisional-home"
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir -p "$home/state/watchdog"
  mkdir "$lock"
  touch -t 200001010000 "$lock"
  if FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_active resident' _ "$ROOT/bin/fm-watchdog-lib.sh"; then
    fail 'abandoned pid-less provisional rotation claim remained active'
  fi
  claim=$(FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_claim resident watchdog' _ "$ROOT/bin/fm-watchdog-lib.sh")
  [ -n "$claim" ] || fail 'abandoned provisional rotation claim was not reclaimed'
  [ -s "$lock/pid" ] || fail 'reclaimed provisional rotation claim did not write pid'
  [ -s "$lock/token" ] || fail 'reclaimed provisional rotation claim did not write token'
  FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_release resident "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$claim"
  [ ! -e "$lock" ] || fail 'reclaimed provisional rotation claim did not release cleanly'
  pass 'abandoned pid-less provisional rotation claim is recovered'
}

test_stale_initialized_cleanup_does_not_remove_replacement_claim() {
  local home lock old_identity
  home="$TMP_ROOT/stale-initialized-aba-home"
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir -p "$home/state/watchdog"
  mkdir "$lock"
  printf '999999999\n' > "$lock/pid"
  printf 'manual\n' > "$lock/owner"
  printf 'old-token\n' > "$lock/token"
  printf '2000-01-01T00:00:00Z\n' > "$lock/created_at"
  old_identity=$(FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_lock_identity "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$lock")
  rm -f "$lock/pid" "$lock/owner" "$lock/token" "$lock/created_at"
  rmdir "$lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  printf 'watchdog\n' > "$lock/owner"
  printf 'replacement-token\n' > "$lock/token"
  printf '2026-01-01T00:00:00Z\n' > "$lock/created_at"
  if FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_remove_lock_if_identity "$2" "$3"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$lock" "$old_identity"; then
    fail 'stale initialized cleanup removed a replacement claim'
  fi
  [ "$(sed -n '1p' "$lock/token")" = replacement-token ] || fail 'replacement initialized claim token was corrupted'
  [ "$(sed -n '1p' "$lock/pid")" = "$$" ] || fail 'replacement initialized claim pid was corrupted'
  pass 'stale initialized cleanup is fenced from replacement claims'
}

test_abandoned_provisional_cleanup_does_not_remove_replacement_claim() {
  local home lock old_identity
  home="$TMP_ROOT/abandoned-provisional-aba-home"
  lock="$home/state/watchdog/.resident-rotation-resident"
  mkdir -p "$home/state/watchdog"
  mkdir "$lock"
  touch -t 200001010000 "$lock"
  old_identity=$(FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_lock_identity "$2"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$lock")
  rmdir "$lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  printf 'watchdog\n' > "$lock/owner"
  printf 'replacement-token\n' > "$lock/token"
  printf '2026-01-01T00:00:00Z\n' > "$lock/created_at"
  if FM_HOME="$home" bash -c '. "$1"; fm_watchdog_rotation_remove_lock_if_identity "$2" "$3"' _ "$ROOT/bin/fm-watchdog-lib.sh" "$lock" "$old_identity"; then
    fail 'abandoned provisional cleanup removed a replacement claim'
  fi
  [ "$(sed -n '1p' "$lock/token")" = replacement-token ] || fail 'replacement provisional claim token was corrupted'
  [ "$(sed -n '1p' "$lock/pid")" = "$$" ] || fail 'replacement provisional claim pid was corrupted'
  pass 'abandoned provisional cleanup is fenced from replacement claims'
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

test_legacy_missing_kind_defaults_to_ship() {
  local fixture home fakebin sessions out
  fixture=$(make_fixture legacy-kind); home=$(printf '%s\n' "$fixture" | sed -n '1p'); fakebin=$(printf '%s\n' "$fixture" | sed -n '2p'); sessions=$(printf '%s\n' "$fixture" | sed -n '3p')
  sed -i.bak '/^kind=/d' "$home/state/resident.meta"
  out=$(run_fixture "$home" "$fakebin" "$sessions" claude --dry-run)
  assert_contains "$out" 'predecessor task=resident sid=resident-session' 'legacy missing kind did not default to ship'
  pass 'legacy missing kind defaults to ship'
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
test_refuses_live_resident_rotation_claim
test_dry_run_allows_stale_initialized_claim_readonly
test_dry_run_refuses_live_initialized_claim_readonly
test_dry_run_refuses_fresh_provisional_claim_readonly
test_recovers_stale_resident_rotation_claim
test_rotation_claim_token_fences_reacquired_lock
test_provisional_rotation_claim_blocks_contenders
test_abandoned_provisional_rotation_claim_is_recovered
test_stale_initialized_cleanup_does_not_remove_replacement_claim
test_abandoned_provisional_cleanup_does_not_remove_replacement_claim
test_refuses_no_live_resident
test_invokes_shared_successor_helper
test_mutating_rotation_locks_before_liveness_lookup
test_refuses_unsupported_resident_kind
test_legacy_missing_kind_defaults_to_ship
test_codex_dry_run_does_not_write_rollout_cache
echo "PASS: $PASS tests"
