#!/usr/bin/env bash
# Behavior tests for Child Node producer birth (CN-P).
# Public interface: fm-child-node-setup.sh / fm-child-node-publish.sh under crews/<task>/.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEST_ROOT=$(fm_test_tmproot fm-child-node)
HOME_DIR="$TEST_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects"

# Parent God Node must exist; birth links to its provision container_id.
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
PARENT_ID=$(jq -r '.container_id' "$HOME_DIR/.god-node/provision.json")
[[ "$PARENT_ID" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
  || fail "parent God Node provision missing UUID-v4"

TASK_ID=crew-a-k3
CHILD_HOME="$HOME_DIR/crews/$TASK_ID"
CONTRACT="$CHILD_HOME/.child-node/contract.json"
PROVISION="$CHILD_HOME/.child-node/provision.json"
CHILD="$CHILD_HOME/.child-node/child.json"
POINTER="$CHILD_HOME/state/child-current.json"

run_setup() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-child-node-setup.sh" "$TASK_ID" --kind ship
}

if bash -c '. "$1"; fm_child_node_valid_uuid_v4 zzzzzzzz-zzzz-4zzz-azzz-zzzzzzzzzzzz' \
  _ "$ROOT/bin/fm-child-node-lib.sh"; then
  fail "UUID-v4 validator accepted non-hexadecimal components"
fi
if bash -c '. "$1"; fm_child_node_valid_uuid_v4 --------------4----8----------------' \
  _ "$ROOT/bin/fm-child-node-lib.sh"; then
  fail "UUID-v4 validator accepted dashes as component data"
fi
bash -c '. "$1"; fm_child_node_valid_uuid_v4 12345678-9abc-4def-8abc-1234567890ab' \
  _ "$ROOT/bin/fm-child-node-lib.sh" \
  || fail "UUID-v4 validator rejected a hexadecimal UUID-v4"

# --- slice 1: birth writes the three immutable docs under crews/<task>/.child-node/ ---
run_setup
[ -f "$CONTRACT" ] || fail "setup did not write contract.json under crews/$TASK_ID/.child-node/"
[ -f "$PROVISION" ] || fail "setup did not write provision.json under crews/$TASK_ID/.child-node/"
[ -f "$CHILD" ] || fail "setup did not write child.json under crews/$TASK_ID/.child-node/"
jq -e '.schema == "dev.vellum.child-node/1" and .minimum_reader == 1' "$CONTRACT" >/dev/null \
  || fail "contract.json schema mismatch"
bash -c '. "$1"; fm_child_node_provision_valid "$2"' _ "$ROOT/bin/fm-child-node-lib.sh" "$PROVISION" \
  || fail "provision.json is not the complete Child Node provision shape"
CHILD_ID=$(jq -r '.container_id' "$PROVISION")
pass "setup writes contract, provision, and child under crews/<task>/.child-node/"

# --- slice 2: parent link is God Node provision id (durable), not god: session wire id ---
jq -e --arg parent "$PARENT_ID" '
  .schema == "dev.vellum.child/1"
  and .parent.kind == "god-node"
  and .parent.container_id == $parent
  and (.parent.container_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.parent.container_id | startswith("god:") | not)
' "$CHILD" >/dev/null \
  || fail "child.json parent.container_id is not the God Node provision UUID"
pass "parent link is God Node provision container_id"

# --- slice 3: idempotent provision - never replace container_id on respawn ---
FIRST_CHILD_ID=$CHILD_ID
run_setup
[ "$(jq -r '.container_id' "$PROVISION")" = "$FIRST_CHILD_ID" ] \
  || fail "idempotent setup replaced immutable Child Node container identity"
# Corrupted/non-provision content must refuse, not clobber (unconditional-write trap).
BAD_HOME="$TEST_ROOT/bad-provision-home"
mkdir -p "$BAD_HOME/crews/bad-k1/.child-node" "$BAD_HOME/state" "$BAD_HOME/data" "$BAD_HOME/config" "$BAD_HOME/projects"
cp -a "$HOME_DIR/.god-node" "$BAD_HOME/.god-node"
printf '%s\n' '{"not":"a-provision"}' > "$BAD_HOME/crews/bad-k1/.child-node/provision.json"
set +e
BAD_OUT=$(FM_HOME="$BAD_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-child-node-setup.sh" bad-k1 --kind ship 2>&1)
BAD_RC=$?
set -e
[ "$BAD_RC" -ne 0 ] || fail "setup overwrote a non-provision provision.json instead of refusing"
[ "$(cat "$BAD_HOME/crews/bad-k1/.child-node/provision.json")" = '{"not":"a-provision"}' ] \
  || fail "setup clobbered operator-owned provision.json content"
case "$BAD_OUT" in
  *refusing*) ;;
  *) fail "setup did not report refuse-to-overwrite for invalid provision.json" ;;
esac
# Half-formed provision (schema + container_id only) must NOT keep as valid identity.
HALF_HOME="$TEST_ROOT/half-provision-home"
mkdir -p "$HALF_HOME/crews/half-k1/.child-node" "$HALF_HOME/state" "$HALF_HOME/data" "$HALF_HOME/config" "$HALF_HOME/projects"
cp -a "$HOME_DIR/.god-node" "$HALF_HOME/.god-node"
HALF_BEFORE='{"schema":"dev.vellum.child-node.provision/1","container_id":"12345678-9abc-4def-8abc-1234567890ab"}'
printf '%s\n' "$HALF_BEFORE" > "$HALF_HOME/crews/half-k1/.child-node/provision.json"
if bash -c '. "$1"; fm_child_node_provision_valid "$2"' _ "$ROOT/bin/fm-child-node-lib.sh" \
  "$HALF_HOME/crews/half-k1/.child-node/provision.json"; then
  fail "complete-shape predicate accepted a provision missing created_at and identity_kind"
fi
set +e
HALF_OUT=$(FM_HOME="$HALF_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-child-node-setup.sh" half-k1 --kind ship 2>&1)
HALF_RC=$?
set -e
[ "$HALF_RC" -ne 0 ] || fail "setup treated a half-formed provision as a valid keep-identity"
[ "$(cat "$HALF_HOME/crews/half-k1/.child-node/provision.json")" = "$HALF_BEFORE" ] \
  || fail "setup clobbered half-formed provision content"
case "$HALF_OUT" in
  *refusing*) ;;
  *) fail "setup did not refuse half-formed provision as invalid shape" ;;
esac
WRONG_KIND_HOME="$TEST_ROOT/wrong-kind-provision-home"
mkdir -p "$WRONG_KIND_HOME/crews/wk-k1/.child-node" "$WRONG_KIND_HOME/state" "$WRONG_KIND_HOME/data" "$WRONG_KIND_HOME/config" "$WRONG_KIND_HOME/projects"
cp -a "$HOME_DIR/.god-node" "$WRONG_KIND_HOME/.god-node"
WRONG_KIND_BEFORE='{"schema":"dev.vellum.child-node.provision/1","container_id":"12345678-9abc-4def-8abc-1234567890ab","created_at":"2026-07-29T00:00:00Z","identity_kind":"not-child-container"}'
printf '%s\n' "$WRONG_KIND_BEFORE" > "$WRONG_KIND_HOME/crews/wk-k1/.child-node/provision.json"
set +e
WRONG_KIND_RC=$(FM_HOME="$WRONG_KIND_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-child-node-setup.sh" wk-k1 --kind ship >/dev/null 2>&1; echo $?)
set -e
[ "$WRONG_KIND_RC" -ne 0 ] || fail "setup accepted wrong identity_kind as valid provision shape"
[ "$(cat "$WRONG_KIND_HOME/crews/wk-k1/.child-node/provision.json")" = "$WRONG_KIND_BEFORE" ] \
  || fail "setup clobbered wrong-identity_kind provision content"
for invalid_created_at in 2026-99-99T99:99:99Z 2026-02-29T00:00:00Z; do
  INVALID_TIME_HOME="$TEST_ROOT/invalid-time-${invalid_created_at//:/-}"
  INVALID_TIME_PROVISION="$INVALID_TIME_HOME/crews/time-k1/.child-node/provision.json"
  mkdir -p "$INVALID_TIME_HOME/crews/time-k1/.child-node" \
    "$INVALID_TIME_HOME/state" "$INVALID_TIME_HOME/data" "$INVALID_TIME_HOME/config" "$INVALID_TIME_HOME/projects"
  cp -a "$HOME_DIR/.god-node" "$INVALID_TIME_HOME/.god-node"
  jq -n --arg created_at "$invalid_created_at" '{
    schema:"dev.vellum.child-node.provision/1",
    container_id:"12345678-9abc-4def-8abc-1234567890ab",
    created_at:$created_at,
    identity_kind:"child-container"
  }' > "$INVALID_TIME_PROVISION"
  if bash -c '. "$1"; fm_child_node_provision_valid "$2"' _ \
    "$ROOT/bin/fm-child-node-lib.sh" "$INVALID_TIME_PROVISION"; then
    fail "complete-shape predicate accepted impossible created_at $invalid_created_at"
  fi
  if bash -c '. "$1"; fm_child_node_container_id "$2"' _ \
    "$ROOT/bin/fm-child-node-lib.sh" "$INVALID_TIME_HOME/crews/time-k1"; then
    fail "container_id extraction bypassed impossible created_at $invalid_created_at"
  fi
  set +e
  INVALID_TIME_OUT=$(FM_HOME="$INVALID_TIME_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-child-node-setup.sh" time-k1 --kind ship 2>&1)
  INVALID_TIME_RC=$?
  set -e
  [ "$INVALID_TIME_RC" -ne 0 ] \
    || fail "setup accepted impossible created_at $invalid_created_at as a valid provision shape"
  case "$INVALID_TIME_OUT" in
    *refusing*) ;;
    *) fail "setup did not refuse impossible created_at $invalid_created_at" ;;
  esac
done
pass "complete provision shape is required; half-formed docs are refused not published as valid"

RACE_HOME="$TEST_ROOT/race-home"
RACE_TASK=race-k2
RACE_PROVISION="$RACE_HOME/crews/$RACE_TASK/.child-node/provision.json"
RACE_FAKEBIN=$(fm_fakebin "$TEST_ROOT/race-fake")
RACE_A_READY="$TEST_ROOT/race-a.ready"
RACE_B_READY="$TEST_ROOT/race-b.ready"
RACE_A_ID=11111111-1111-4111-8111-111111111111
RACE_B_ID=22222222-2222-4222-8222-222222222222
mkdir -p "$RACE_HOME/state" "$RACE_HOME/data" "$RACE_HOME/config" "$RACE_HOME/projects"
cp -a "$HOME_DIR/.god-node" "$RACE_HOME/.god-node"
cat > "$RACE_FAKEBIN/uuidgen" <<'SH'
#!/usr/bin/env bash
set -eu
: > "$FM_UUID_READY"
wait_count=0
while [ ! -e "$FM_UUID_PEER" ]; do
  sleep 0.01
  wait_count=$((wait_count + 1))
  [ "$wait_count" -lt 1000 ] || exit 1
done
if [ -n "${FM_UUID_WAIT_FOR_FILE:-}" ]; then
  wait_count=0
  while [ ! -e "$FM_UUID_WAIT_FOR_FILE" ]; do
    sleep 0.01
    wait_count=$((wait_count + 1))
    [ "$wait_count" -lt 1000 ] || exit 1
  done
fi
printf '%s\n' "$FM_UUID_VALUE"
SH
chmod +x "$RACE_FAKEBIN/uuidgen"
FM_HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$ROOT" PATH="$RACE_FAKEBIN:$PATH" \
  FM_UUID_READY="$RACE_A_READY" FM_UUID_PEER="$RACE_B_READY" FM_UUID_VALUE="$RACE_A_ID" \
  "$ROOT/bin/fm-child-node-setup.sh" "$RACE_TASK" --kind ship \
  >"$TEST_ROOT/race-a.out" 2>&1 &
RACE_A_PID=$!
FM_HOME="$RACE_HOME" FM_ROOT_OVERRIDE="$ROOT" PATH="$RACE_FAKEBIN:$PATH" \
  FM_UUID_READY="$RACE_B_READY" FM_UUID_PEER="$RACE_A_READY" FM_UUID_VALUE="$RACE_B_ID" \
  FM_UUID_WAIT_FOR_FILE="$RACE_PROVISION" \
  "$ROOT/bin/fm-child-node-setup.sh" "$RACE_TASK" --kind ship \
  >"$TEST_ROOT/race-b.out" 2>&1 &
RACE_B_PID=$!
RACE_A_RC=0
RACE_B_RC=0
wait "$RACE_A_PID" || RACE_A_RC=$?
wait "$RACE_B_PID" || RACE_B_RC=$?
[ "$RACE_A_RC" -eq 0 ] || fail "first concurrent setup failed: $(cat "$TEST_ROOT/race-a.out")"
[ "$RACE_B_RC" -eq 0 ] || fail "second concurrent setup failed: $(cat "$TEST_ROOT/race-b.out")"
[ "$(jq -r '.container_id' "$RACE_PROVISION")" = "$RACE_A_ID" ] \
  || fail "later concurrent setup replaced the first provision identity"
pass "idempotent setup preserves identity and refuses clobber of invalid provision"

# --- slice 4: first child-current pointer (atomic birth publish) ---
publish() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CHILD_BACKEND_KIND=herdr FM_CHILD_WORKSPACE_ID=ws-1 FM_CHILD_PANE_ID=pane-9 \
    "$ROOT/bin/fm-child-node-publish.sh" "$TASK_ID" "$@"
}
publish starting
jq -e --arg id "$FIRST_CHILD_ID" --arg parent "$PARENT_ID" '
  .schema == "dev.vellum.child-current/1"
  and .container_id == $id
  and .parent_container_id == $parent
  and .epoch == 1
  and .lifecycle == "starting"
  and .task_id == "crew-a-k3"
  and .child_type == "firstmate-crew"
  and .backend == {kind:"herdr",workspace_id:"ws-1",pane_id:"pane-9"}
  and (.parent_container_id | startswith("god:") | not)
' "$POINTER" >/dev/null \
  || fail "first child-current pointer content mismatch"
publish ready
jq -e --arg id "$FIRST_CHILD_ID" '
  .container_id == $id and .epoch == 2 and .lifecycle == "ready"
' "$POINTER" >/dev/null \
  || fail "republish did not monotically increment epoch"
pass "first child-current pointer publishes with durable parent and monotonic epoch"

# --- slice 5: failed atomic write leaves previous complete pointer intact ---
BEFORE=$(sha256sum "$POINTER" | awk '{print $1}')
if printf '%s\n' '{invalid' | bash -c '
  # shellcheck source=bin/fm-resident-lib.sh
  . "$1"
  fm_resident_atomic_json "$2"
' "$ROOT/bin/fm-resident-lib.sh" "$POINTER" 2>/dev/null; then
  fail "invalid temporary JSON unexpectedly replaced child-current"
fi
AFTER=$(sha256sum "$POINTER" | awk '{print $1}')
[ "$BEFORE" = "$AFTER" ] || fail "failed pre-rename write changed the published child-current"
pass "failed pre-rename writes leave the previous complete child-current intact"

# --- slice 6: secondmate path is the same birth contract (not a special case) ---
SM_ID=sm-domain-q1
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-child-node-setup.sh" "$SM_ID" --kind secondmate
SM_HOME="$HOME_DIR/crews/$SM_ID"
jq -e --arg parent "$PARENT_ID" '
  .schema == "dev.vellum.child/1"
  and .child_type == "firstmate-secondmate"
  and .parent.kind == "god-node"
  and .parent.container_id == $parent
' "$SM_HOME/.child-node/child.json" >/dev/null \
  || fail "secondmate child.json did not use the same parent-link birth contract"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_CHILD_BACKEND_KIND=tmux FM_CHILD_WORKSPACE_ID=sess FM_CHILD_PANE_ID=%1 \
  "$ROOT/bin/fm-child-node-publish.sh" "$SM_ID" starting
jq -e --arg parent "$PARENT_ID" '
  .schema == "dev.vellum.child-current/1"
  and .child_type == "firstmate-secondmate"
  and .parent_container_id == $parent
  and .task_id == "sm-domain-q1"
  and .lifecycle == "starting"
' "$SM_HOME/state/child-current.json" >/dev/null \
  || fail "secondmate first child-current mismatched birth contract"
pass "secondmate path uses the same Child Node birth contract"

# --- slice 7: fm-spawn birth writes Child Node docs for ship and secondmate ---
SPAWN="$ROOT/bin/fm-spawn.sh"
make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# Ship crew spawn through adopt-worktree (isolated WT already present).
SPAWN_CASE="$TEST_ROOT/spawn-ship"
SPAWN_HOME="$SPAWN_CASE/home"
SPAWN_PROJ="$SPAWN_CASE/project"
SPAWN_WT="$SPAWN_CASE/wt"
SPAWN_FAKE=$(make_spawn_fakebin "$SPAWN_CASE/fake")
mkdir -p "$SPAWN_HOME/data" "$SPAWN_HOME/projects" "$SPAWN_HOME/state" "$SPAWN_HOME/config"
printf 'claude\n' > "$SPAWN_HOME/config/crew-harness"
fm_git_worktree "$SPAWN_PROJ" "$SPAWN_WT" wt-child-ship
touch "$SPAWN_HOME/state/.last-watcher-beat"
SHIP_ID=child-ship-k9
mkdir -p "$SPAWN_HOME/data/$SHIP_ID"
printf 'brief\n' > "$SPAWN_HOME/data/$SHIP_ID/brief.md"
FM_HOME="$SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
SPAWN_PARENT=$(jq -r '.container_id' "$SPAWN_HOME/.god-node/provision.json")
set +e
SPAWN_OUT=$(
  FM_ROOT_OVERRIDE='' FM_HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" \
    FM_PROJECTS_OVERRIDE="$SPAWN_HOME/projects" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$SPAWN_WT" TMUX="fake,1,0" \
    PATH="$SPAWN_FAKE:$PATH" \
    "$SPAWN" "$SHIP_ID" "$SPAWN_PROJ" \
      --adopt-worktree --adopt-worktree-path "$SPAWN_WT" 2>&1
)
SPAWN_RC=$?
set -e
[ "$SPAWN_RC" -eq 0 ] || fail "ship spawn failed: $SPAWN_OUT"
SHIP_CHILD_HOME="$SPAWN_HOME/crews/$SHIP_ID"
[ -f "$SHIP_CHILD_HOME/.child-node/provision.json" ] \
  || fail "ship spawn did not write Child Node provision under crews/$SHIP_ID"
jq -e --arg parent "$SPAWN_PARENT" '
  .schema == "dev.vellum.child/1"
  and .parent.container_id == $parent
  and (.parent.container_id | startswith("god:") | not)
' "$SHIP_CHILD_HOME/.child-node/child.json" >/dev/null \
  || fail "ship spawn parent link is not God Node provision id"
jq -e --arg parent "$SPAWN_PARENT" '
  .schema == "dev.vellum.child-current/1"
  and .lifecycle == "starting"
  and .parent_container_id == $parent
  and .task_id == "child-ship-k9"
  and .epoch == 1
' "$SHIP_CHILD_HOME/state/child-current.json" >/dev/null \
  || fail "ship spawn did not write first child-current with durable parent"
pass "fm-spawn ship birth writes Child Node docs and first current"

# Secondmate spawn: same birth under primary home crews/<id>/.
# Use the real seeder so marker/AGENTS/bin/registry match production spawn gates.
SM_SPAWN_CASE="$TEST_ROOT/spawn-sm"
SM_SPAWN_HOME="$SM_SPAWN_CASE/home"
SM_SUB_HOME="$SM_SPAWN_CASE/secondmate-home"
SM_FAKE=$(make_spawn_fakebin "$SM_SPAWN_CASE/fake")
mkdir -p "$SM_SPAWN_HOME/data" "$SM_SPAWN_HOME/projects" "$SM_SPAWN_HOME/state" "$SM_SPAWN_HOME/config"
printf 'claude\n' > "$SM_SPAWN_HOME/config/crew-harness"
printf 'claude\n' > "$SM_SPAWN_HOME/config/secondmate-harness"
touch "$SM_SPAWN_HOME/state/.last-watcher-beat"
SM_SPAWN_ID=sm-child-q2
FM_HOME="$SM_SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
SM_PARENT=$(jq -r '.container_id' "$SM_SPAWN_HOME/.god-node/provision.json")
FM_HOME="$SM_SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_SECONDMATE_CHARTER='child node secondmate domain' \
  FM_SECONDMATE_SCOPE='child node secondmate scope' \
  "$ROOT/bin/fm-home-seed.sh" "$SM_SPAWN_ID" "$SM_SUB_HOME" --no-projects >/dev/null \
  || fail "secondmate home seed failed for spawn birth test"
set +e
SM_OUT=$(
  FM_ROOT_OVERRIDE='' FM_HOME="$SM_SPAWN_HOME" \
    FM_STATE_OVERRIDE="$SM_SPAWN_HOME/state" FM_DATA_OVERRIDE="$SM_SPAWN_HOME/data" \
    FM_PROJECTS_OVERRIDE="$SM_SPAWN_HOME/projects" FM_CONFIG_OVERRIDE="$SM_SPAWN_HOME/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$SM_FAKE:$PATH" \
    "$SPAWN" "$SM_SPAWN_ID" "$SM_SUB_HOME" --secondmate 2>&1
)
SM_RC=$?
set -e
[ "$SM_RC" -eq 0 ] || fail "secondmate spawn failed: $SM_OUT"
SM_CHILD_HOME="$SM_SPAWN_HOME/crews/$SM_SPAWN_ID"
jq -e --arg parent "$SM_PARENT" '
  .schema == "dev.vellum.child/1"
  and .child_type == "firstmate-secondmate"
  and .parent.container_id == $parent
' "$SM_CHILD_HOME/.child-node/child.json" >/dev/null \
  || fail "secondmate spawn did not write same-contract Child Node descriptor"
jq -e '
  .schema == "dev.vellum.child-current/1"
  and .lifecycle == "starting"
  and .child_type == "firstmate-secondmate"
' "$SM_CHILD_HOME/state/child-current.json" >/dev/null \
  || fail "secondmate spawn missing first child-current"
pass "fm-spawn secondmate birth writes Child Node docs under crews/<task>"

# --- slice 8: birth publish carries conversation harness + worktree from meta ---
# Non-claude harness is required: claude is the accidental default consumers invent
# when the field is absent, so a claude assertion cannot catch this bug.
META_PATH="$HOME_DIR/state/$TASK_ID.meta"
fm_write_meta "$META_PATH" \
  "window=fm-$TASK_ID" \
  "worktree=/tmp/fm-child-node-wt-codex" \
  "harness=codex" \
  "kind=ship" \
  "mode=no-mistakes" \
  "yolo=off"
publish starting
jq -e '
  .harness == "codex"
  and .worktree == "/tmp/fm-child-node-wt-codex"
' "$POINTER" >/dev/null \
  || fail "child-current missing harness/worktree from meta (got: $(jq -c '{harness,worktree}' "$POINTER" 2>/dev/null || cat "$POINTER"))"
pass "child-current publishes non-claude harness and worktree from task meta"

# --- slice 9: unknown harness/worktree stay absent (never invent claude or a path) ---
ABSENT_ID=absent-hw-k1
ABSENT_HOME="$HOME_DIR/crews/$ABSENT_ID"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-child-node-setup.sh" "$ABSENT_ID" --kind ship
# No meta file, no FM_CHILD_HARNESS / FM_CHILD_WORKTREE — publish must omit both fields.
rm -f "$HOME_DIR/state/$ABSENT_ID.meta"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_CHILD_BACKEND_KIND=herdr FM_CHILD_WORKSPACE_ID=ws-a FM_CHILD_PANE_ID=pane-a \
  "$ROOT/bin/fm-child-node-publish.sh" "$ABSENT_ID" starting
ABSENT_POINTER="$ABSENT_HOME/state/child-current.json"
jq -e '
  (has("harness") | not)
  and (has("worktree") | not)
' "$ABSENT_POINTER" >/dev/null \
  || fail "absent harness/worktree must be omitted, not defaulted (got: $(jq -c '{harness,worktree}' "$ABSENT_POINTER"))"
# Meta present but keys missing: still omit (do not invent).
fm_write_meta "$HOME_DIR/state/$ABSENT_ID.meta" \
  "window=fm-$ABSENT_ID" \
  "kind=ship"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-child-node-publish.sh" "$ABSENT_ID" starting
jq -e '(has("harness") | not) and (has("worktree") | not)' "$ABSENT_POINTER" >/dev/null \
  || fail "meta without harness/worktree keys must not fabricate values (got: $(jq -c '{harness,worktree}' "$ABSENT_POINTER"))"
pass "unknown harness and worktree are omitted, never fabricated"

# --- slice 10: fm-spawn with non-claude harness publishes matching child-current ---
SPAWN_CODEX_CASE="$TEST_ROOT/spawn-codex"
SPAWN_CODEX_HOME="$SPAWN_CODEX_CASE/home"
SPAWN_CODEX_PROJ="$SPAWN_CODEX_CASE/project"
SPAWN_CODEX_WT="$SPAWN_CODEX_CASE/wt"
SPAWN_CODEX_FAKE=$(make_spawn_fakebin "$SPAWN_CODEX_CASE/fake")
mkdir -p "$SPAWN_CODEX_HOME/data" "$SPAWN_CODEX_HOME/projects" "$SPAWN_CODEX_HOME/state" "$SPAWN_CODEX_HOME/config"
# Explicit codex so the assertion cannot pass by accident on a missing field.
printf 'codex\n' > "$SPAWN_CODEX_HOME/config/crew-harness"
fm_git_worktree "$SPAWN_CODEX_PROJ" "$SPAWN_CODEX_WT" wt-child-codex
touch "$SPAWN_CODEX_HOME/state/.last-watcher-beat"
CODEX_SHIP_ID=child-codex-k2
mkdir -p "$SPAWN_CODEX_HOME/data/$CODEX_SHIP_ID"
printf 'brief\n' > "$SPAWN_CODEX_HOME/data/$CODEX_SHIP_ID/brief.md"
FM_HOME="$SPAWN_CODEX_HOME" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-resident-setup.sh"
set +e
SPAWN_CODEX_OUT=$(
  FM_ROOT_OVERRIDE='' FM_HOME="$SPAWN_CODEX_HOME" \
    FM_STATE_OVERRIDE="$SPAWN_CODEX_HOME/state" FM_DATA_OVERRIDE="$SPAWN_CODEX_HOME/data" \
    FM_PROJECTS_OVERRIDE="$SPAWN_CODEX_HOME/projects" FM_CONFIG_OVERRIDE="$SPAWN_CODEX_HOME/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$SPAWN_CODEX_WT" TMUX="fake,1,0" \
    PATH="$SPAWN_CODEX_FAKE:$PATH" \
    "$SPAWN" "$CODEX_SHIP_ID" "$SPAWN_CODEX_PROJ" \
      --harness codex \
      --adopt-worktree --adopt-worktree-path "$SPAWN_CODEX_WT" 2>&1
)
SPAWN_CODEX_RC=$?
set -e
[ "$SPAWN_CODEX_RC" -eq 0 ] || fail "codex ship spawn failed: $SPAWN_CODEX_OUT"
CODEX_CHILD_POINTER="$SPAWN_CODEX_HOME/crews/$CODEX_SHIP_ID/state/child-current.json"
CODEX_META="$SPAWN_CODEX_HOME/state/$CODEX_SHIP_ID.meta"
[ -f "$CODEX_META" ] || fail "codex spawn did not write task meta"
META_HARNESS=$(grep '^harness=' "$CODEX_META" | cut -d= -f2-)
META_WT=$(grep '^worktree=' "$CODEX_META" | cut -d= -f2-)
[ "$META_HARNESS" = codex ] || fail "codex spawn meta harness=$META_HARNESS, want codex"
jq -e --arg h "$META_HARNESS" --arg w "$META_WT" '
  .harness == $h
  and .worktree == $w
  and .harness == "codex"
' "$CODEX_CHILD_POINTER" >/dev/null \
  || fail "codex spawn child-current harness/worktree mismatch meta (child=$(jq -c '{harness,worktree}' "$CODEX_CHILD_POINTER"); meta harness=$META_HARNESS worktree=$META_WT)"
pass "fm-spawn non-claude harness and worktree match child-current"