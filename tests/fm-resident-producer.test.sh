#!/usr/bin/env bash
# Behavior tests for the Crew Lead resident-container producer contract.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_ROOT=$(fm_test_tmproot fm-resident)
HOME_DIR="$TEST_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

run_setup() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
}

publish() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RESIDENT_PID="$$" FM_RESIDENT_HARNESS=codex \
    FM_RESIDENT_BACKEND_KIND=herdr FM_RESIDENT_WORKSPACE_ID=crew-lead \
    FM_RESIDENT_PANE_ID=pane-1 "$ROOT/bin/fm-resident-publish.sh" "$@"
}

run_setup
CONTAINER_ID=$(jq -r '.container_id' "$HOME_DIR/.god-node/provision.json")
[[ "$CONTAINER_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
  || fail "setup did not provision a UUID-v4 container_id"
FIRST_ID=$CONTAINER_ID
run_setup
[ "$(jq -r '.container_id' "$HOME_DIR/.god-node/provision.json")" = "$FIRST_ID" ] \
  || fail "idempotent setup replaced immutable container identity"
jq -e 'has("container_id") == false and has("created_at") == false and has("identity_kind") == false' "$HOME_DIR/.god-node/contract.json" >/dev/null \
  || fail "tracked contract retained local container identity"
jq -e '.schema == "dev.vellum.resident/1" and .resident_version == "dev.vellum.firstmate-resident/1" and .contract_versions == [1] and .entrypoints.adopt == ["bin/fm-resident-adopt.sh"]' "$HOME_DIR/.god-node/resident.json" >/dev/null \
  || fail "setup did not write the versioned resident manifest"
for cap in input.file-v1 input.backend-v1 crew.bridge-v1 \
  transcript.claude-jsonl-v1 transcript.codex-rollout-v1 transcript.grok-chat-history-v1 \
  transcript.cursor-agent-transcript-v1 transcript.opencode-db-v1 transcript.pi-session-jsonl-v1 \
  transcript.hermes-state-db-v1; do
  jq -e --arg cap "$cap" '.capabilities | index($cap) != null' \
    "$HOME_DIR/.god-node/resident.json" >/dev/null \
    || fail "setup omitted capability $cap"
done
git -C "$ROOT" check-ignore -q inbox/requests/request.json \
  || fail "file-v1 request inbox path is not ignored operational data"
git -C "$ROOT" check-ignore -q inbox/results/result.json \
  || fail "file-v1 result inbox path is not ignored operational data"
SECOND_HOME="$TEST_ROOT/second-home"
mkdir -p "$SECOND_HOME/.god-node" "$SECOND_HOME/state" "$SECOND_HOME/data" "$SECOND_HOME/config" "$SECOND_HOME/projects"
cp "$HOME_DIR/.god-node/contract.json" "$SECOND_HOME/.god-node/contract.json"
FM_HOME="$SECOND_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
[ "$(jq -r '.container_id' "$SECOND_HOME/.god-node/provision.json")" != "$FIRST_ID" ] \
  || fail "copied tracked contract reused the first home container identity"
pass "provisioning creates local immutable identity and versioned manifest"

# Prove a full publication cycle (setup rewrite + lock-path republish) never drops
# crew.bridge-v1. Simulate a pre-fix partial descriptor, then re-setup and lock.
PARTIAL_CAPS_HOME="$TEST_ROOT/partial-caps-home"
mkdir -p "$PARTIAL_CAPS_HOME/state" "$PARTIAL_CAPS_HOME/data" "$PARTIAL_CAPS_HOME/config" "$PARTIAL_CAPS_HOME/projects" "$PARTIAL_CAPS_HOME/.god-node"
cp "$HOME_DIR/.god-node/contract.json" "$PARTIAL_CAPS_HOME/.god-node/contract.json"
FM_HOME="$PARTIAL_CAPS_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
# Corrupt the descriptor to the historical 4-cap set that gated the crew bridge off.
jq 'del(.capabilities[] | select(. == "crew.bridge-v1"))' \
  "$PARTIAL_CAPS_HOME/.god-node/resident.json" > "$PARTIAL_CAPS_HOME/.god-node/resident.json.tmp"
mv "$PARTIAL_CAPS_HOME/.god-node/resident.json.tmp" "$PARTIAL_CAPS_HOME/.god-node/resident.json"
jq -e '.capabilities | index("crew.bridge-v1") == null' "$PARTIAL_CAPS_HOME/.god-node/resident.json" >/dev/null \
  || fail "partial-caps fixture still carried crew.bridge-v1 before repair"
FAKEBIN_CAPS=$(fm_fakebin "$TEST_ROOT/caps-fakebin")
cat > "$FAKEBIN_CAPS/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf 'codex\n' ;;
  *"args="*) printf 'codex test harness\n' ;;
  *"ppid="*) printf '1\n' ;;
esac
SH
chmod +x "$FAKEBIN_CAPS/ps"
# Session lock always re-runs setup then publish; this is the production rewrite path.
PATH="$FAKEBIN_CAPS:$PATH" FM_HOME="$PARTIAL_CAPS_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-lock.sh" >/dev/null
jq -e '.capabilities | index("crew.bridge-v1") != null' \
  "$PARTIAL_CAPS_HOME/.god-node/resident.json" >/dev/null \
  || fail "session-lock republication dropped crew.bridge-v1"
# A second standalone setup rewrite must keep the full set (idempotent repair).
FM_HOME="$PARTIAL_CAPS_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
for cap in input.file-v1 input.backend-v1 crew.bridge-v1 \
  transcript.claude-jsonl-v1 transcript.codex-rollout-v1 transcript.grok-chat-history-v1 \
  transcript.cursor-agent-transcript-v1 transcript.opencode-db-v1 transcript.pi-session-jsonl-v1 \
  transcript.hermes-state-db-v1; do
  jq -e --arg cap "$cap" '.capabilities | index($cap) != null' \
    "$PARTIAL_CAPS_HOME/.god-node/resident.json" >/dev/null \
    || fail "standalone setup rewrite dropped capability $cap"
done
pass "publication cycle keeps crew.bridge-v1"

LOCK_HOME="$TEST_ROOT/lock-home"
mkdir -p "$LOCK_HOME/state/resident-current.json"
FAKEBIN=$(fm_fakebin "$TEST_ROOT")
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf 'codex\n' ;;
  *"args="*) printf 'codex test harness\n' ;;
  *"ppid="*) printf '1\n' ;;
esac
SH
chmod +x "$FAKEBIN/ps"
set +e
LOCK_OUTPUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$LOCK_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-lock.sh" 2>&1)
LOCK_STATUS=$?
set -e
[ "$LOCK_STATUS" -ne 0 ] || fail "fm-lock succeeded after resident publication failed"
case "$LOCK_OUTPUT" in
  *"lock acquired"*) fail "fm-lock printed success after resident publication failed" ;;
esac
[ ! -e "$LOCK_HOME/state/.lock" ] || fail "fm-lock left a new live session lock after resident publication failed"
pass "session lock acquisition fails closed when resident publication fails"

STALE_HOME="$TEST_ROOT/stale-lock-home"
mkdir -p "$STALE_HOME/state/resident-current.lock"
printf '999999\n' > "$STALE_HOME/state/resident-current.lock/pid"
FM_HOME="$STALE_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RESIDENT_PID="$$" FM_RESIDENT_HARNESS=codex \
  FM_RESIDENT_BACKEND_KIND=herdr FM_RESIDENT_WORKSPACE_ID=crew-lead \
  FM_RESIDENT_PANE_ID=pane-1 "$ROOT/bin/fm-resident-publish.sh" ready
jq -e '.schema == "dev.vellum.resident-current/1" and .epoch == 1' "$STALE_HOME/state/resident-current.json" >/dev/null \
  || fail "stale publisher lock recovery did not publish a pointer"
[ ! -e "$STALE_HOME/state/resident-current.lock" ] || fail "stale publisher lock recovery left the lock held"
pass "publisher lock recovers abandoned owner state"

TRANSCRIPT_ONE="$TEST_ROOT/rollout-one.jsonl"
TRANSCRIPT_TWO="$TEST_ROOT/rollout-two.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"session_id":"session-one"}}' > "$TRANSCRIPT_ONE"
printf '%s\n' '{"type":"session_meta","payload":{"session_id":"session-two"}}' > "$TRANSCRIPT_TWO"
FM_RESIDENT_TRANSCRIPT="$TRANSCRIPT_ONE" FM_RESIDENT_SESSION_ID=session-one publish ready
FIRST_EPOCH=$(jq -r '.epoch' "$HOME_DIR/state/resident-current.json")
FM_RESIDENT_TRANSCRIPT="$TRANSCRIPT_TWO" FM_RESIDENT_SESSION_ID=session-two publish ready
jq -e --arg id "$FIRST_ID" --arg path "$TRANSCRIPT_TWO" --argjson previous "$FIRST_EPOCH" '
  .schema == "dev.vellum.resident-current/1"
  and .container_id == $id
  and .epoch == ($previous + 1)
  and .conversation.session_id == "session-two"
  and .conversation.transcript.path == $path
  and .backend == {kind:"herdr",workspace_id:"crew-lead",pane_id:"pane-1"}
  and .input.transport == "backend-v1"
  and (.process.creation_identity | startswith("linux-proc-v1:") or startswith("ps-lstart-v1:"))
' "$HOME_DIR/state/resident-current.json" >/dev/null || fail "rotation did not publish a coherent incremented pointer"
pass "session rotation publishes endpoint, transcript, process identity, and monotonic epoch"

BEFORE=$(sha256sum "$HOME_DIR/state/resident-current.json" | awk '{print $1}')
if printf '%s\n' '{invalid' | fm_resident_atomic_json_test="$ROOT/bin/fm-resident-lib.sh" bash -c '. "$fm_resident_atomic_json_test"; fm_resident_atomic_json "$1"' _ "$HOME_DIR/state/resident-current.json" 2>/dev/null; then
  fail "invalid temporary JSON unexpectedly replaced the pointer"
fi
AFTER=$(sha256sum "$HOME_DIR/state/resident-current.json" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail "failed pre-rename write changed the published pointer"
pass "failed pre-rename writes leave the previous complete pointer intact"

for N in 1 2 3 4 5; do
  FM_RESIDENT_SESSION_ID="concurrent-$N" FM_RESIDENT_TRANSCRIPT="$TRANSCRIPT_ONE" publish ready &
done
wait
[ "$(jq -r '.epoch' "$HOME_DIR/state/resident-current.json")" -eq $((FIRST_EPOCH + 6)) ] \
  || fail "concurrent publishers lost an epoch increment"
jq -e . "$HOME_DIR/state/resident-current.json" >/dev/null || fail "concurrent publishers exposed partial JSON"
pass "concurrent publishers serialize atomic epoch updates"

FM_RESIDENT_BACKEND_KIND=unknown FM_RESIDENT_WORKSPACE_ID='' FM_RESIDENT_PANE_ID='' \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_RESIDENT_PID="$$" \
  FM_RESIDENT_HARNESS=unknown "$ROOT/bin/fm-resident-publish.sh" waiting
jq -e '.input.transport == "file-v1" and has("backend") == false and has("conversation") == false' \
  "$HOME_DIR/state/resident-current.json" >/dev/null || fail "headless publication did not advertise the file transport"
pass "standalone headless publication uses the file-v1 input baseline"

publish stopped
jq -e '.lifecycle == "stopped" and has("process") == false and has("backend") == false and .input.transport == "file-v1"' \
  "$HOME_DIR/state/resident-current.json" >/dev/null || fail "clean stop retained live process or backend fields"
pass "clean stop preserves the pointer while clearing live endpoint fields"
