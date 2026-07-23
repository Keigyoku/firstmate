#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh --role worktree skill injection (C3 Option 2).
#
# Role-tagged crew/scout spawns must place a discoverable role skill into the
# task worktree for Claude and Grok project-skill conventions, exclude the
# injected paths from git so they cannot land in a product PR, and record
# role= in task meta. Role is explicit -- never inferred from the task id.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-role-skill)

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
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf '%s\n' "$harness" > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3
  shift 3
  HOME="${FM_TEST_HOME:-$HOME}" \
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

read_case_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# Observable contract: role-tagged ship spawn injects a resolvable skill symlink,
# hides it from git status porcelain, mirrors .claude/skills when needed, and
# records role= in meta.
test_role_tagged_spawn_injects_excluded_skill() {
  local rec id out status link target excl porcelain claude_skills skill_md
  id=role-review-z1
  rec=$(make_spawn_case role-review claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --role review-crew)
  status=$?
  expect_code 0 "$status" "role-tagged ship spawn should succeed"
  assert_contains "$out" "spawned $id" "spawn did not report success"

  link="$WT_DIR/.agents/skills/review-crew"
  assert_present "$link" "role skill symlink missing at $link"
  [ -L "$link" ] || fail "role skill path is not a symlink: $link"
  target=$(readlink "$link")
  assert_contains "$target" "/.agents/skills/review-crew" \
    "role skill symlink does not point at firstmate role skill dir"
  skill_md="$link/SKILL.md"
  assert_present "$skill_md" "injected role skill is not resolvable (SKILL.md missing)"

  claude_skills="$WT_DIR/.claude/skills"
  assert_present "$claude_skills" ".claude/skills layout missing for Claude discovery"
  [ -L "$claude_skills" ] || fail ".claude/skills should be a symlink to .agents/skills"
  assert_present "$claude_skills/review-crew/SKILL.md" \
    "Claude skills path does not resolve the injected role skill"

  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  assert_present "$excl" "git info/exclude was not created"
  assert_grep ".agents/skills/review-crew" "$excl" "injected role skill path not git-excluded"
  assert_grep ".claude/skills" "$excl" ".claude/skills symlink not git-excluded"

  porcelain=$(git -C "$WT_DIR" status --porcelain)
  assert_not_contains "$porcelain" ".agents" "injected .agents path visible in git status porcelain"
  assert_not_contains "$porcelain" ".claude" "injected .claude path visible in git status porcelain"
  assert_not_contains "$porcelain" "review-crew" "role skill name visible in git status porcelain"

  assert_grep "role=review-crew" "$HOME_DIR/state/$id.meta" "meta missing role=review-crew"
  pass "role-tagged spawn injects resolvable, git-excluded role skill and records role="
}

test_role_tag_rejects_unknown_role() {
  local rec id out status
  id=role-bad-z2
  rec=$(make_spawn_case role-bad claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --role not-a-crew)
  status=$?
  expect_code 1 "$status" "unknown --role should fail"
  assert_contains "$out" "--role" "unknown role error should mention --role"
  assert_absent "$HOME_DIR/state/$id.meta" "failed role spawn should not write meta"
  assert_absent "$WT_DIR/.agents/skills/not-a-crew" "unknown role must not inject a skill"
  pass "unknown --role is rejected without injection"
}

test_role_not_inferred_from_task_id() {
  local rec id out status
  id=review-crew-lookalike-z3
  rec=$(make_spawn_case role-no-infer claude "$id")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "spawn without --role should succeed"
  assert_absent "$WT_DIR/.agents/skills/review-crew" \
    "role skill must not be inferred from task id text"
  assert_no_grep "role=" "$HOME_DIR/state/$id.meta" "meta must not record role= without --role"
  pass "role is not inferred from task id"
}

test_role_tagged_spawn_injects_excluded_skill
test_role_tag_rejects_unknown_role
test_role_not_inferred_from_task_id

echo "# all fm-spawn-role-skill tests passed"
