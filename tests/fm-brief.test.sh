#!/usr/bin/env bash
# Behavior tests for bin/fm-brief.sh.
#
# Regression coverage for the heredoc-in-command-substitution parse bug (issue
# #166): each ship-mode branch builds its Definition-of-done text with
# `VAR=$(cat <<EOF ... EOF)`. Bash's lexer tracks quote state through the
# heredoc body while it scans for the matching `)` of the command
# substitution, so a single unescaped apostrophe anywhere in that body breaks
# parsing of the *entire rest of the script* - `bash -n` fails, not just the
# generated brief. A plain `cat > file <<EOF ... EOF` (not wrapped in `$(...)`)
# is unaffected, so the secondmate charter block does not need this guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-brief)

# The script itself must always parse. This is the direct regression test for
# issue #166: a stray apostrophe in any of the three DOD heredoc bodies
# (no-mistakes/direct-PR/local-only) breaks `bash -n` on the whole file.
test_script_parses() {
  bash -n "$ROOT/bin/fm-brief.sh" 2>&1 || fail "bin/fm-brief.sh fails bash -n (heredoc/quote regression)"
  pass "fm-brief.sh: bash -n succeeds"
}

test_help_includes_entire_header() {
  local help
  help=$("$ROOT/bin/fm-brief.sh" --help)
  assert_contains "$help" "Refuses to overwrite an existing brief." "fm-brief.sh --help omitted its header terminator"
  pass "fm-brief.sh: --help renders the complete header"
}

# Registry with one project per delivery mode, so each ship-mode DOD branch is
# exercised. A project absent from the registry defaults to no-mistakes.
write_registry() {
  local home=$1
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- direct-proj [direct-PR] - fixture for direct-PR mode (added 2026-07-01)
- local-proj [local-only] - fixture for local-only mode (added 2026-07-01)
EOF
}

# fm-brief.sh must exit 0 and produce a brief with no unreplaced shell
# metacharacter corruption for every ship delivery mode. This also guards
# against any *new* unescaped apostrophe or unbalanced quote later added to
# one of these DOD blocks, since a broken heredoc corrupts or empties the
# generated brief content, not just the script's own syntax.
test_ship_modes_generate_clean_briefs() {
  local home id brief status
  home="$TMP_ROOT/ship-home"
  write_registry "$home"

  for id_proj in "brief-nomistakes-a1:no-registry-proj" "brief-directpr-a2:direct-proj" "brief-localonly-a3:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1; status=$?
    expect_code 0 "$status" "fm-brief.sh $id $proj should exit 0"
    brief="$home/data/$id/brief.md"
    assert_present "$brief" "$id: brief was not scaffolded"
    assert_grep "# Definition of done" "$brief" "$id: brief missing Definition of done section"
    assert_grep "{TASK}" "$brief" "$id: brief missing the {TASK} placeholder"
    assert_no_grep "EOF" "$brief" "$id: brief leaked a heredoc EOF marker (unterminated heredoc)"
  done
  pass "fm-brief.sh: no-mistakes/direct-PR/local-only briefs generate cleanly"
}

# Pin the specific line the bug lived on: the no-mistakes DOD's no-mistakes
# reference must render as plain prose with no dangling apostrophe artifact.
test_no_mistakes_dod_wording() {
  local home id brief
  home="$TMP_ROOT/wording-home"
  mkdir -p "$home/data"
  id="brief-wording-b1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "no-mistakes itself provides for the mechanics" "$brief" \
    "no-mistakes DOD lost its guidance-reference sentence"
  assert_no_grep "no-mistakes' own guidance" "$brief" \
    "no-mistakes DOD regressed to the apostrophe form that breaks bash -n"
  pass "fm-brief.sh: no-mistakes DOD wording avoids the apostrophe regression"
}

test_ship_project_memory_wording() {
  local home id brief
  home="$TMP_ROOT/project-memory-home"
  mkdir -p "$home/data"
  id="brief-memory-c1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "brief was not scaffolded"
  assert_grep "Record only project knowledge useful to almost every future session." "$brief" \
    "project-memory contract lost the durable-knowledge bar"
  assert_grep "prefer a pointer to the authoritative file, command, or doc over copying the detail" "$brief" \
    "project-memory contract lost pointer-over-copy guidance"
  assert_grep "lacks \`## Maintaining this file\`, add that short self-governance section" "$brief" \
    "project-memory contract lost the self-governance add-in-same-pass rule"
  pass "fm-brief.sh: ship project-memory wording carries the AGENTS.md authoring bar"
}

test_herdr_lab_contract_is_explicit_and_complete() {
  local home id brief
  home="$TMP_ROOT/herdr-lab-home"
  mkdir -p "$home/data"
  id="brief-herdr-lab-d1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "Herdr lab brief was not scaffolded"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "Herdr lab brief missing its hard safety contract"
  assert_grep "never assign it to a shell variable and call" "$brief" \
    "Herdr lab brief must warn against a variable-invoked helper"
  assert_grep "HERDR_LAB_SESSION=\$('$ROOT/bin/fm-herdr-lab.sh' name $id)" "$brief" \
    "Herdr lab brief must name the session via the literal helper path"
  assert_grep "'$ROOT/bin/fm-herdr-lab.sh' provision \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing literal-path provisioning"
  assert_grep "'$ROOT/bin/fm-herdr-lab.sh' teardown \"\$HERDR_LAB_SESSION\"" "$brief" \
    "Herdr lab brief missing literal-path teardown"
  assert_no_grep "\"\$HERDR_LAB_HELPER\" teardown" "$brief" \
    "Herdr lab brief must not invoke the helper through a shell variable (crew guard denies a variable command word)"
  assert_grep "required trailing \`--session \"\$HERDR_LAB_SESSION\"\`" "$brief" \
    "Herdr lab brief missing the per-call trailing session contract"
  assert_grep "direct \`herdr server stop\`" "$brief" \
    "Herdr lab brief missing the forbidden server-global command list"
  assert_grep "records the live default session before provisioning" "$brief" \
    "Herdr lab brief missing the before tripwire"
  assert_grep "verifies the identical fleet state after teardown" "$brief" \
    "Herdr lab brief missing the after tripwire"
  assert_no_grep "Herdr lifecycle declaration - NOT ENABLED" "$brief" \
    "Herdr lab brief retained the unguarded declaration"
  pass "fm-brief.sh: --herdr-lab emits the complete hard safety contract"
}

test_herdr_lab_contract_quotes_foreign_firstmate_path() {
  local home id brief foreign_root helper
  home="$TMP_ROOT/herdr-lab-foreign-home"
  foreign_root="$TMP_ROOT/firstmate helper's root"
  mkdir -p "$home/data"
  id="brief-herdr-lab-foreign-d2"
  helper=$(printf '%s' "$foreign_root/bin/fm-herdr-lab.sh" | sed "s/'/'\\\\''/g")
  helper="'$helper'"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$foreign_root" "$ROOT/bin/fm-brief.sh" "$id" foreign --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_grep "$helper teardown" "$brief" \
    "Herdr lab brief must invoke the shell-quoted absolute Firstmate helper path"
  assert_no_grep "bin/fm-herdr-lab.sh name $id" "$brief" \
    "Herdr lab brief must not invoke a worktree-relative helper"
  pass "fm-brief.sh: --herdr-lab uses its quoted Firstmate-owned helper path"
}

test_herdr_lab_omission_is_loud_for_ship_and_scout() {
  local home id brief
  home="$TMP_ROOT/herdr-gate-home"
  mkdir -p "$home/data"
  for kind in ship scout; do
    id="brief-herdr-gate-$kind"
    if [ "$kind" = scout ]; then
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
    else
      FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
    fi
    brief="$home/data/$id/brief.md"
    assert_grep "# Herdr lifecycle declaration - NOT ENABLED" "$brief" \
      "$kind brief silently omitted the Herdr declaration"
    assert_grep "regenerate the brief with \`--herdr-lab\` before dispatch" "$brief" \
      "$kind brief missing the fail-visible regeneration instruction"
  done
  pass "fm-brief.sh: ship and scout scaffolds make omitted Herdr intent fail-visible"
}

test_secondmate_no_projects_charter() {
  local home brief status
  home="$TMP_ROOT/no-projects-home"
  mkdir -p "$home/data"

  # The deliberate --no-projects signal scaffolds a valid project-less charter for
  # a domain whose subject is the firstmate repo itself (no clones needed).
  FM_HOME="$home" FM_SECONDMATE_CHARTER='firstmate self-development' \
    FM_SECONDMATE_SCOPE='firstmate repo work' \
    "$ROOT/bin/fm-brief.sh" fdev --secondmate --no-projects >/dev/null 2>&1; status=$?
  expect_code 0 "$status" "--no-projects secondmate brief should exit 0"
  brief="$home/data/fdev/brief.md"
  assert_present "$brief" "project-less charter was not scaffolded"
  assert_grep "# Project clones" "$brief" "project-less charter dropped the Project clones heading"
  assert_grep "None. This is a project-less domain" "$brief" \
    "project-less charter did not render a sensible no-clones note"
  assert_grep "its crews take pooled worktrees of that repo" "$brief" \
    "project-less charter operating model lost the pooled-worktree note"
  assert_no_grep "The projects above are local clones" "$brief" \
    "project-less charter kept the with-projects operating-model line"
  if grep -nE '^-[[:space:]]*$' "$brief" >/dev/null; then
    fail "project-less charter left a stray empty project bullet"
  fi

  # Accidental omission (no projects, no signal) still fails loudly, writing nothing.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops --secondmate >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "secondmate brief with no projects and no --no-projects must fail"
  assert_absent "$home/data/oops/brief.md" "loud-failure secondmate brief still wrote a file"

  # --no-projects is mutually exclusive with a project list.
  FM_HOME="$home" FM_SECONDMATE_CHARTER='x' "$ROOT/bin/fm-brief.sh" oops2 --secondmate --no-projects alpha >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects combined with a project list must fail"

  # --no-projects applies only to secondmate charters, never a ship/scout brief.
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" oops3 somerepo --no-projects >/dev/null 2>&1; status=$?
  expect_code 1 "$status" "--no-projects on a ship brief must fail"

  pass "fm-brief.sh: --no-projects scaffolds a project-less charter and guards misuse"
}

test_herdr_lab_contract_applies_to_scouts_but_not_secondmates() {
  local home brief status=0
  home="$TMP_ROOT/herdr-kind-home"
  mkdir -p "$home/data"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" herdr-scout firstmate --scout --herdr-lab >/dev/null 2>&1
  brief="$home/data/herdr-scout/brief.md"
  assert_grep "# Herdr isolation - HARD SAFETY CONTRACT" "$brief" \
    "scout --herdr-lab brief missing the contract"

  FM_HOME="$home" FM_SECONDMATE_CHARTER=ops "$ROOT/bin/fm-brief.sh" herdr-secondmate --secondmate firstmate --herdr-lab >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "secondmate --herdr-lab must be rejected"
  assert_absent "$home/data/herdr-secondmate/brief.md" \
    "rejected secondmate --herdr-lab still wrote a brief"
  pass "fm-brief.sh: Herdr lab contract covers scouts and rejects secondmate misuse"
}

test_pause_verb_override_renders_all_brief_scaffolds() {
  local home kind id brief
  home="$TMP_ROOT/pause-verb-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-pause-verb-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" FM_CLASSIFY_PAUSED_VERB=awaiting \
          "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep "States: working, needs-decision, blocked, awaiting, done, failed." "$brief" \
      "$kind brief did not render the configured pause verb in its states list"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'Use `awaiting: {why}`' "$brief" \
      "$kind brief did not instruct the configured pause status"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_no_grep '`paused: {why}`' "$brief" \
      "$kind brief still instructs the default paused status"
  done
  pass "fm-brief.sh: custom pause verb renders in every scaffold"
}

# Crew-side half of the paused-absorb contract: when firstmate tells a crew to
# wait/stand by/hold/park, the scaffold must say append paused: then idle - so the
# watcher has an explicit status line to key on (never silent idle alone).
test_briefs_instruct_wait_status_contract() {
  local home kind id brief
  home="$TMP_ROOT/wait-status-contract-home"
  mkdir -p "$home/data"

  for kind in ship scout secondmate; do
    id="brief-wait-contract-$kind"
    case "$kind" in
      ship)
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate >/dev/null 2>&1
        ;;
      scout)
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" firstmate --scout >/dev/null 2>&1
        ;;
      secondmate)
        FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" --secondmate --no-projects >/dev/null 2>&1
        ;;
    esac
    brief="$home/data/$id/brief.md"
    assert_grep 'wait, stand by, hold, or park' "$brief" \
      "$kind brief missing wait/stand-by/hold/park instruction"
    # shellcheck disable=SC2016 # Literal backticks and braces must remain unexpanded.
    assert_grep 'paused: {what you are waiting for}' "$brief" \
      "$kind brief missing explicit paused-what-waiting-for contract line"
  done
  pass "fm-brief.sh: wait-status contract present in every scaffold"
}

# Fleet TDD contract (vellum-tdd-adoption-scout report sec 6.1-6.2, captain locks
# A1 + F1-F4): every ship-mode brief carries the Test-first DoD; scouts stay
# report-only. Also absorbs fm-brief-closes-issue: ship briefs instruct Closes #N.
test_ship_briefs_emit_tdd_contract() {
  local home id brief
  home="$TMP_ROOT/tdd-contract-home"
  write_registry "$home"

  for id_proj in "brief-tdd-nomistakes:no-registry-proj" "brief-tdd-direct:direct-proj" "brief-tdd-local:local-proj"; do
    id=${id_proj%%:*}
    proj=${id_proj##*:}
    FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" "$proj" >/dev/null 2>&1
    brief="$home/data/$id/brief.md"
    assert_grep "# Test-first (fleet standing order)" "$brief" \
      "$id: ship brief missing Test-first DoD heading"
    assert_grep "F1. NO BEHAVIOR CHANGE WITHOUT A FAILING TEST FIRST" "$brief" \
      "$id: ship brief missing iron rule F1"
    assert_grep "F2. RED IS NOT OPTIONAL THEATRE" "$brief" \
      "$id: ship brief missing iron rule F2"
    assert_grep "F3. VERTICAL SLICES ONLY" "$brief" \
      "$id: ship brief missing iron rule F3"
    assert_grep "F4. TESTS ASSERT OBSERVABLE BEHAVIOR" "$brief" \
      "$id: ship brief missing iron rule F4"
    assert_grep "Record RED evidence" "$brief" \
      "$id: ship brief missing A1 RED-evidence requirement"
    assert_grep "Typed exemptions" "$brief" \
      "$id: ship brief missing typed-exemptions table"
    assert_grep "docs/comment-only" "$brief" \
      "$id: ship brief missing docs/comment-only exemption"
    assert_grep "pure renames/moves" "$brief" \
      "$id: ship brief missing pure-rename exemption"
    assert_grep "Closes #N" "$brief" \
      "$id: ship brief missing Closes #N PR-body guidance"
    assert_grep "/tdd" "$brief" \
      "$id: ship brief missing /tdd skill pointer for claude harness"
    assert_grep "$HOME/.claude/skills/tdd/SKILL.md" "$brief" \
      "$id: ship brief missing absolute captain tdd skill path"
    assert_no_grep "__HOME__" "$brief" \
      "$id: ship brief left __HOME__ placeholder unexpanded"
  done
  pass "fm-brief.sh: every ship mode emits the fleet TDD contract, skill pointer, and Closes #N"
}

test_scout_brief_has_no_tdd_contract() {
  local home id brief
  home="$TMP_ROOT/tdd-scout-home"
  mkdir -p "$home/data"
  id="brief-tdd-scout"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "scout brief was not scaffolded"
  assert_no_grep "# Test-first (fleet standing order)" "$brief" \
    "scout brief must not carry the ship TDD DoD"
  assert_no_grep "F1. NO BEHAVIOR CHANGE WITHOUT A FAILING TEST FIRST" "$brief" \
    "scout brief must not carry iron rule F1"
  assert_no_grep "Closes #N" "$brief" \
    "scout brief must not carry Closes #N PR guidance"
  assert_no_grep "/.claude/skills/tdd/SKILL.md" "$brief" \
    "scout brief must not carry the captain tdd skill pointer"
  pass "fm-brief.sh: scout briefs stay free of the ship TDD contract"
}

test_role_line_on_ship_and_scout() {
  local home id brief skill_abs
  home="$TMP_ROOT/role-brief-home"
  mkdir -p "$home/data"
  skill_abs="$ROOT/.agents/skills/review-crew/SKILL.md"

  id="brief-role-ship-r1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --role review-crew >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "role-tagged ship brief was not scaffolded"
  assert_grep "# Role identity" "$brief" "ship brief missing Role identity section"
  assert_grep "Load your role identity: \`/review-crew\`" "$brief" \
    "ship brief missing slash role load instruction"
  assert_grep "read \`$skill_abs\` in full" "$brief" \
    "ship brief missing absolute SKILL.md read fallback"

  id="brief-role-scout-r2"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj --scout --role smoke-crew >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "role-tagged scout brief was not scaffolded"
  assert_grep "Load your role identity: \`/smoke-crew\`" "$brief" \
    "scout brief missing slash role load instruction"
  assert_grep "read \`$ROOT/.agents/skills/smoke-crew/SKILL.md\` in full" "$brief" \
    "scout brief missing absolute SKILL.md read fallback"
  pass "fm-brief.sh: --role inserts load instruction on ship and scout briefs"
}

test_role_rejected_for_secondmate_and_unknown() {
  local home out status
  home="$TMP_ROOT/role-reject-home"
  mkdir -p "$home/data"

  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" role-sm --secondmate --no-projects --role review-crew 2>&1) || status=$?
  status=${status:-0}
  expect_code 1 "$status" "--role with --secondmate should fail"
  assert_contains "$out" "--role" "secondmate role rejection should mention --role"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" role-bad some-proj --role not-a-crew 2>&1) || status=$?
  expect_code 1 "$status" "unknown --role should fail"
  assert_contains "$out" "review-crew" "unknown role error should list allowed roles"
  pass "fm-brief.sh: --role rejects secondmate and unknown names"
}

# Fresh-branch (default) vs existing-branch (--on-branch) Setup contracts.
# Fixes the ambiguous "pipeline lands on wrong PR / no PR found" path:
# scaffold said "create your branch: git checkout -b fm/<task-id>" while {TASK}
# prose said to stack on an existing PR branch. Crews that obeyed the scaffold
# opened task-named branches with no PR (e.g. #835 body-fix), and a later task-named
# local branch could misdirect delivery after work started on the target branch
# (composer-fix #836). These assertions cover those branch-name failure classes,
# not unrelated delivery failures: the create-branch string must be ABSENT and the
# local branch name must equal the target at setup and delivery.
test_fresh_branch_setup_creates_task_branch() {
  local home id brief
  home="$TMP_ROOT/fresh-branch-home"
  mkdir -p "$home/data"
  id="brief-fresh-branch-f1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "fresh-branch brief was not scaffolded"
  assert_grep "create your branch: \`git checkout -b fm/$id\`" "$brief" \
    "default ship brief must still emit the create-branch first action"
  assert_grep "git checkout -b fm/$id" "$brief" \
    "default ship brief must name the task branch create command"
  assert_no_grep "do NOT create a new branch" "$brief" \
    "default ship brief must not carry existing-branch custody prose"
  pass "fm-brief.sh: default ship Setup still creates the task branch"
}

test_on_branch_setup_checks_out_existing_without_create() {
  local home id brief branch pr_url expect_head
  home="$TMP_ROOT/on-branch-home"
  mkdir -p "$home/data"
  id="brief-on-branch-o1"
  branch="fm/vellum-voice-e2e-g7"
  pr_url="https://github.com/Keigyoku/vellum-app/pull/830"
  expect_head="81fae0b6abc123"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj \
    --on-branch "$branch" --pr "$pr_url" --expect-head "$expect_head" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"
  assert_present "$brief" "existing-branch brief was not scaffolded"

  # Critical: no create-branch instruction anywhere (the bug class oracle).
  assert_no_grep "git checkout -b" "$brief" \
    "existing-branch brief must not contain git checkout -b anywhere"
  assert_no_grep "create your branch" "$brief" \
    "existing-branch brief must not say create your branch"
  assert_no_grep "fm/$id" "$brief" \
    "existing-branch brief must not invent a task-named branch"

  # Checkout the named branch, not a new one.
  assert_grep "git fetch origin '$branch' && git checkout -B '$branch' 'origin/$branch'" "$brief" \
    "existing-branch brief must reset the named local branch from its remote"
  assert_grep "$branch" "$brief" \
    "existing-branch brief must name the target branch"
  assert_grep "do NOT create a new branch" "$brief" \
    "existing-branch brief must forbid creating a new branch"
  assert_grep "git worktree list --porcelain" "$brief" \
    "existing-branch brief must identify a linked worktree that holds the branch"
  assert_grep "firstmate must free it" "$brief" \
    "existing-branch brief must block for branch custody handoff"
  assert_grep "Do not use a detached HEAD" "$brief" \
    "existing-branch brief must forbid a wrong-name fallback"
  assert_grep "test \"\$(git rev-parse --abbrev-ref HEAD)\" = '$branch'" "$brief" \
    "existing-branch brief must assert the local branch name"
  assert_grep "immediately before invoking /no-mistakes" "$brief" \
    "existing-branch brief must repeat the local-name check before delivery"
  assert_grep "blocked: wrong local branch for delivery gate, expected '$branch' got <actual>" "$brief" \
    "existing-branch brief must block delivery from the wrong local branch"

  # Expected-head assertion with blocked: stop, reporting actual sha.
  assert_grep "$expect_head" "$brief" \
    "existing-branch brief must carry the expected head"
  assert_grep "blocked:" "$brief" \
    "existing-branch brief must stop with blocked: on unexpected head"
  assert_grep "git rev-parse HEAD" "$brief" \
    "existing-branch brief must assert HEAD via git rev-parse"

  # Explicit PR association so the delivery gate updates that PR, not opens one.
  assert_grep "$pr_url" "$brief" \
    "existing-branch brief must name the PR URL"
  assert_grep "Do not open a new PR" "$brief" \
    "existing-branch brief must forbid opening a replacement PR"
  assert_grep "updates" "$brief" \
    "existing-branch brief must state that pushes update the existing PR"

  # Custody rules formerly pasted by hand into {TASK}.
  assert_grep "Never force-push" "$brief" \
    "existing-branch brief missing never force-push custody rule"
  assert_grep "never reset" "$brief" \
    "existing-branch brief missing never reset custody rule"
  assert_grep "abort" "$brief" \
    "existing-branch brief missing abort-stale-run custody rule"
  assert_grep "git ls-remote" "$brief" \
    "existing-branch brief missing ls-remote post-push confirmation"
  pass "fm-brief.sh: --on-branch Setup checks out existing branch with no create"
}

test_on_branch_shell_quotes_command_values() {
  local home id brief branch pr_url expect_head
  home="$TMP_ROOT/on-branch-quoting-home"
  mkdir -p "$home/data"
  id="brief-on-branch-q1"
  # shellcheck disable=SC2016 # Literal expansion syntax is the injection payload.
  branch='fm/review-$x;`touch-pwn`'
  # shellcheck disable=SC2016 # Literal expansion syntax is the injection payload.
  pr_url='https://example.invalid/pull/42?x=$y;`touch-pwn`'
  # shellcheck disable=SC2016 # Literal expansion syntax is the injection payload.
  expect_head='abc123$z;`touch-pwn`'
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" some-proj \
    --on-branch "$branch" --pr "$pr_url" --expect-head "$expect_head" >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "git fetch origin '$branch' && git checkout -B '$branch' 'origin/$branch'" "$brief" \
    "branch interpolations in checkout setup must be shell-quoted"
  assert_grep "git ls-remote origin 'refs/heads/$branch'" "$brief" \
    "branch interpolation in ls-remote command must be shell-quoted"
  assert_grep "case \"\$(git rev-parse HEAD)\" in '$expect_head'*)" "$brief" \
    "expected-head interpolation in assertion command must be shell-quoted"
  assert_grep "expected '$pr_url'" "$brief" \
    "PR interpolation in blocked command text must be shell-quoted"
  assert_no_grep "git checkout -B $branch" "$brief" \
    "branch metacharacters must not render as an unquoted checkout argument"
  pass "fm-brief.sh: --on-branch shell-quotes generated command values"
}

test_on_branch_local_only_has_local_custody() {
  local home id brief out status
  home="$TMP_ROOT/on-branch-local-home"
  write_registry "$home"
  id="brief-on-branch-local-l1"
  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" "$id" local-proj \
    --on-branch fm/local-stack --expect-head abc123 >/dev/null 2>&1
  brief="$home/data/$id/brief.md"

  assert_grep "git switch -- 'fm/local-stack'" "$brief" \
    "local-only existing-branch brief must switch to the local branch"
  assert_no_grep "git fetch origin" "$brief" \
    "local-only existing-branch brief must not require an origin fetch"
  assert_no_grep "git ls-remote" "$brief" \
    "local-only existing-branch brief must not require remote-tip verification"
  assert_no_grep "stale pipeline" "$brief" \
    "local-only existing-branch brief must not mention pipeline custody"
  assert_no_grep "Never force-push" "$brief" \
    "local-only existing-branch brief must not emit remote custody rules"
  assert_no_grep "open a new PR" "$brief" \
    "local-only existing-branch brief must not discuss replacement PRs"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" onb-local-pr local-proj \
    --on-branch fm/local-stack --pr 42 2>&1) || status=$?
  expect_code 1 "$status" "--pr with local-only delivery should fail"
  assert_contains "$out" "local-only" "local-only --pr rejection should name the delivery mode"
  assert_absent "$home/data/onb-local-pr/brief.md" \
    "rejected local-only --pr request still wrote a brief"
  pass "fm-brief.sh: local-only --on-branch stays local and rejects --pr"
}

test_on_branch_rejects_misuse() {
  local home out status
  home="$TMP_ROOT/on-branch-reject-home"
  mkdir -p "$home/data"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" onb-scout some-proj --scout --on-branch fm/x 2>&1) || status=$?
  expect_code 1 "$status" "--on-branch with --scout should fail"
  assert_contains "$out" "--on-branch" "scout rejection should mention --on-branch"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" onb-sm --secondmate --no-projects --on-branch fm/x 2>&1) || status=$?
  expect_code 1 "$status" "--on-branch with --secondmate should fail"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" onb-pr-only some-proj --pr 830 2>&1) || status=$?
  expect_code 1 "$status" "--pr without --on-branch should fail"
  assert_contains "$out" "--on-branch" "--pr rejection should require --on-branch"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" onb-head-only some-proj --expect-head abcdef 2>&1) || status=$?
  expect_code 1 "$status" "--expect-head without --on-branch should fail"

  status=0
  out=$(FM_HOME="$home" "$ROOT/bin/fm-brief.sh" onb-empty some-proj --on-branch 2>&1) || status=$?
  expect_code 1 "$status" "--on-branch without a value should fail"

  pass "fm-brief.sh: --on-branch rejects scout/secondmate and orphan flags"
}

test_script_parses
test_help_includes_entire_header
test_ship_modes_generate_clean_briefs
test_no_mistakes_dod_wording
test_ship_project_memory_wording
test_herdr_lab_contract_is_explicit_and_complete
test_herdr_lab_contract_quotes_foreign_firstmate_path
test_herdr_lab_omission_is_loud_for_ship_and_scout
test_herdr_lab_contract_applies_to_scouts_but_not_secondmates
test_secondmate_no_projects_charter
test_pause_verb_override_renders_all_brief_scaffolds
test_briefs_instruct_wait_status_contract
test_ship_briefs_emit_tdd_contract
test_scout_brief_has_no_tdd_contract
test_role_line_on_ship_and_scout
test_role_rejected_for_secondmate_and_unknown
test_fresh_branch_setup_creates_task_branch
test_on_branch_setup_checks_out_existing_without_create
test_on_branch_shell_quotes_command_values
test_on_branch_local_only_has_local_custody
test_on_branch_rejects_misuse
