#!/usr/bin/env bash
# Behavior tests for the primary claim-vs-evidence guard (docs/turnend-guard.md).
#
# Hermetic over temp dirs; no live harness is invoked here.
# Live Claude Stop-hook validation is recorded in docs/turnend-guard.md.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claim-guard)
fm_git_identity fmtest fmtest@example.invalid

install_claim_scripts() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/docs"
  cp "$ROOT/bin/fm-claim-guard.sh" "$dir/bin/fm-claim-guard.sh"
  cp "$ROOT/bin/fm-glass.sh" "$dir/bin/fm-glass.sh"
  cp "$ROOT/bin/fm-turnend-guard.sh" "$dir/bin/fm-turnend-guard.sh"
  # Composed Stop-hook tests run turnend first; it sources these.
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-supervision-instructions.sh" "$dir/bin/fm-supervision-instructions.sh"
  cp "$ROOT/bin/fm-harness.sh" "$dir/bin/fm-harness.sh"
  cp -R "$ROOT/docs/supervision-protocols" "$dir/docs/supervision-protocols"
  chmod +x "$dir/bin/fm-claim-guard.sh" "$dir/bin/fm-glass.sh" "$dir/bin/fm-turnend-guard.sh" \
    "$dir/bin/fm-supervision-instructions.sh" "$dir/bin/fm-harness.sh"
}

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/, state/.
make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state" "$dir/fm-state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_claim_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-test-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/claim-guard-test-branch
  mkdir -p "$dir/state" "$dir/fm-state"
  : > "$dir/AGENTS.md"
  install_claim_scripts "$dir"
  printf '%s\n' "$dir"
}

# Write a minimal Claude-shaped JSONL transcript with one final assistant text.
write_transcript() {
  local path=$1 text=$2
  mkdir -p "$(dirname -- "$path")"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"ping"}}'
    jq -cn --arg t "$text" \
      '{type:"assistant",isSidechain:false,message:{role:"assistant",content:[{type:"text",text:$t}]}}'
  } > "$path"
}

write_stale_marker() {
  local home=$1
  mkdir -p "$home/fm-state"
  # Epoch far in the past (2020-01-01) — always older than the 15m window.
  printf '%s %s\n' '1577836800' '/tmp/stale-glass.png' > "$home/fm-state/last-glass-capture"
}

write_fresh_marker() {
  local home=$1 path=${2:-/tmp/fresh-glass.png}
  mkdir -p "$home/fm-state"
  printf '%s %s\n' "$(date +%s)" "$path" > "$home/fm-state/last-glass-capture"
}

run_claim_hook() {
  local dir=$1 payload=$2
  local home
  home=$(cd "$dir" && pwd)
  printf '%s' "$payload" | CLAUDECODE=1 CLAUDE_PROJECT_DIR="$home" FM_HOME="$home" \
    bash "$dir/bin/fm-claim-guard.sh" 2>&1
}

payload_for() {
  local transcript=$1 stop_active=${2:-false} message=${3:-}
  if [ -n "$message" ]; then
    jq -cn --arg t "$transcript" --argjson a "$stop_active" --arg m "$message" \
      '{transcript_path:$t, stop_hook_active:$a, last_assistant_message:$m}'
  else
    jq -cn --arg t "$transcript" --argjson a "$stop_active" \
      '{transcript_path:$t, stop_hook_active:$a}'
  fi
}

# Prefer last_assistant_message (what Claude Stop actually supplies at hook time).
payload_with_message() {
  local message=$1 stop_active=${2:-false}
  jq -cn --arg m "$message" --argjson a "$stop_active" \
    '{last_assistant_message:$m, stop_hook_active:$a}'
}

CLAIM_TEXT='Captain, the vellum dashboard is rendering and working after the boot.'
NO_CLAIM_TEXT='Crewmate is still working on the backlog item; no app status yet.'

test_claim_no_evidence_blocks() {
  local dir out status payload
  dir=$(make_primary_dir "$TMP_ROOT/claim-block")
  write_stale_marker "$dir"
  payload=$(payload_with_message "$CLAIM_TEXT" false)
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 2 "$status" "claim without fresh glass must block"
  assert_contains "$out" 'UNVERIFIED APP-STATE CLAIM' "block banner missing"
  assert_contains "$out" 'bin/fm-glass.sh' "remedy must name bin/fm-glass.sh"
  pass "fm-claim-guard: claim + no/stale evidence blocks"
}

test_claim_fresh_evidence_allows() {
  local dir out status payload
  dir=$(make_primary_dir "$TMP_ROOT/claim-allow-fresh")
  write_fresh_marker "$dir"
  payload=$(payload_with_message "$CLAIM_TEXT" false)
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 0 "$status" "claim with fresh glass must allow"
  [ -z "$out" ] || fail "fresh-evidence allow must be silent, got: $out"
  pass "fm-claim-guard: claim + fresh evidence allows"
}

test_no_claim_allows() {
  local dir out status payload
  dir=$(make_primary_dir "$TMP_ROOT/claim-no-claim")
  # No marker at all — still allow when the message is not an app-state claim.
  payload=$(payload_with_message "$NO_CLAIM_TEXT" false)
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 0 "$status" "non-claim message must allow without glass"
  [ -z "$out" ] || fail "no-claim allow must be silent, got: $out"
  pass "fm-claim-guard: no app-state claim allows"
}

test_stop_hook_active_allows() {
  local dir out status payload
  dir=$(make_primary_dir "$TMP_ROOT/claim-loop")
  write_stale_marker "$dir"
  payload=$(payload_with_message "$CLAIM_TEXT" true)
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 0 "$status" "stop_hook_active=true must allow (one block per turn)"
  [ -z "$out" ] || fail "loop-guard allow must be silent, got: $out"
  pass "fm-claim-guard: stop_hook_active allows"
}

test_missing_transcript_fails_open() {
  local dir out status payload home
  dir=$(make_primary_dir "$TMP_ROOT/claim-no-tx")
  home=$(cd "$dir" && pwd)
  # No last_assistant_message and no transcript_path => fail open.
  payload='{"stop_hook_active":false}'
  out=$(printf '%s' "$payload" | CLAUDECODE=1 CLAUDE_PROJECT_DIR="$home" FM_HOME="$home" \
    bash "$dir/bin/fm-claim-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "missing message+transcript must fail open"
  # transcript_path points at a missing file, no last_assistant_message.
  payload=$(jq -cn --arg t "$dir/does-not-exist.jsonl" '{transcript_path:$t,stop_hook_active:false}')
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 0 "$status" "missing transcript file must fail open"
  pass "fm-claim-guard: missing transcript fails open"
}

test_transcript_fallback_blocks() {
  local dir out status transcript payload
  dir=$(make_primary_dir "$TMP_ROOT/claim-tx-fallback")
  transcript="$dir/transcript.jsonl"
  write_transcript "$transcript" "$CLAIM_TEXT"
  write_stale_marker "$dir"
  # No last_assistant_message — force the JSONL fallback path.
  payload=$(payload_for "$transcript" false)
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 2 "$status" "transcript fallback must still block claims without glass"
  assert_contains "$out" 'UNVERIFIED APP-STATE CLAIM' "transcript fallback block banner missing"
  pass "fm-claim-guard: transcript_path fallback blocks without last_assistant_message"
}

test_non_primary_scope_allows() {
  local dir base out status payload home
  # Secondmate home
  dir=$(make_secondmate_dir "$TMP_ROOT/claim-sm")
  write_stale_marker "$dir"
  payload=$(payload_with_message "$CLAIM_TEXT" false)
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 0 "$status" "secondmate home must not run the claim guard"
  # Crewmate linked worktree
  base="$TMP_ROOT/claim-crew-base"
  dir=$(make_crewmate_worktree_dir "$base" "$TMP_ROOT/claim-crew-wt")
  write_stale_marker "$dir"
  home=$(cd "$dir" && pwd)
  payload=$(payload_with_message "$CLAIM_TEXT" false)
  out=$(printf '%s' "$payload" | CLAUDECODE=1 CLAUDE_PROJECT_DIR="$home" FM_HOME="$home" \
    bash "$dir/bin/fm-claim-guard.sh" 2>&1); status=$?
  expect_code 0 "$status" "crewmate worktree must not run the claim guard"
  pass "fm-claim-guard: non-primary scope allows"
}

test_local_disable_off() {
  local dir out status payload
  dir=$(make_primary_dir "$TMP_ROOT/claim-off")
  printf 'off\n' > "$dir/config/claim-guard"
  write_stale_marker "$dir"
  payload=$(payload_with_message "$CLAIM_TEXT" false)
  out=$(run_claim_hook "$dir" "$payload"); status=$?
  expect_code 0 "$status" "config/claim-guard=off must disable the guard"
  pass "fm-claim-guard: local off disables"
}

test_composed_stop_hook_runs_both() {
  local dir out status payload home
  dir=$(make_primary_dir "$TMP_ROOT/claim-compose")
  write_stale_marker "$dir"
  # No in-flight work => turnend allows; claim must still block.
  home=$(cd "$dir" && pwd)
  payload=$(payload_with_message "$CLAIM_TEXT" false)
  # shellcheck disable=SC2016 # Literal tracked /bin/sh Stop-hook command shape.
  out=$(
    printf '%s' "$payload" | (
      cd "$dir" && env CLAUDECODE=1 CLAUDE_PROJECT_DIR="$home" FM_HOME="$home" \
        /bin/sh -c 'payload=$(cat); root=${CLAUDE_PROJECT_DIR:-$(pwd -P)}; if [ -f "$root/AGENTS.md" ] && [ -f "$root/bin/fm-turnend-guard.sh" ]; then printf "%s" "$payload" | "$root/bin/fm-turnend-guard.sh" || exit $?; if [ -f "$root/bin/fm-claim-guard.sh" ]; then printf "%s" "$payload" | "$root/bin/fm-claim-guard.sh"; fi; fi'
    ) 2>&1
  ); status=$?
  expect_code 2 "$status" "composed Stop hook must still block on claim without glass"
  assert_contains "$out" 'UNVERIFIED APP-STATE CLAIM' "composed hook must surface claim banner"
  pass "fm-claim-guard: composed Claude Stop hook still blocks claims"
}

test_settings_hook_invokes_claim_guard() {
  local settings command
  settings="$ROOT/.claude/settings.json"
  [ -f "$settings" ] || fail "tracked .claude/settings.json is missing"
  command=$(jq -r '.hooks.Stop[0].hooks[0].command // empty' "$settings")
  [ -n "$command" ] || fail "Stop hook command is missing from .claude/settings.json"
  assert_contains "$command" 'fm-turnend-guard.sh' "Stop hook must still invoke fm-turnend-guard.sh"
  assert_contains "$command" 'fm-claim-guard.sh' "Stop hook must invoke fm-claim-guard.sh after turnend"
  pass ".claude/settings.json: Stop hook composes turnend then claim guard"
}

test_glass_records_marker() {
  local dir fakebin out marker status sock
  dir=$(make_primary_dir "$TMP_ROOT/glass-marker")
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/spectacle" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 1
printf 'PNG' > "$out"
exit 0
SH
  chmod +x "$fakebin/spectacle"
  mkdir -p "$dir/run"
  sock="$dir/run/wayland-0"
  # Pathname Unix socket remains on disk after bind; hold a child so it stays valid.
  python3 -c "
import os, socket, time
p = '$sock'
try:
    os.unlink(p)
except FileNotFoundError:
    pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
s.listen(1)
if os.fork() == 0:
    time.sleep(30)
    raise SystemExit(0)
" >/dev/null
  [ -S "$sock" ] || fail "failed to create fake Wayland socket at $sock"
  out=$(
    PATH="$fakebin:$PATH" \
    XDG_RUNTIME_DIR="$dir/run" WAYLAND_DISPLAY=wayland-0 \
    FM_HOME="$dir" \
    bash "$dir/bin/fm-glass.sh" "$dir/out.png" 2>&1
  ); status=$?
  expect_code 0 "$status" "fm-glass.sh must succeed with stub spectacle"
  assert_contains "$out" "$dir/out.png" "fm-glass.sh must print the capture path"
  assert_present "$dir/out.png" "capture file missing"
  marker="$dir/fm-state/last-glass-capture"
  assert_present "$marker" "freshness marker missing"
  assert_grep "$dir/out.png" "$marker" "marker must record the output path"
  pass "fm-glass: records freshness marker and prints path"
}

test_claim_no_evidence_blocks
test_claim_fresh_evidence_allows
test_no_claim_allows
test_stop_hook_active_allows
test_missing_transcript_fails_open
test_transcript_fallback_blocks
test_non_primary_scope_allows
test_local_disable_off
test_composed_stop_hook_runs_both
test_settings_hook_invokes_claim_guard
test_glass_records_marker
