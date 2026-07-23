#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
target=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-t" ]; then target=$arg; fi
  prev=$arg
done
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_command*)
        case "$target" in
          *dead-secondmate*) printf 'zsh\n' ;;
          *) printf 'codex\n' ;;
        esac
        ;;
      *) printf '%%1\n' ;;
    esac
    ;;
  capture-pane)
    case "$target" in
      *ship-task*) printf 'work in progress\nesc to interrupt\n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

write_fixture() {  # <home>
  local home=$1
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-task.meta" \
    "window=firstmate:fm-scout-task" \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    "window=firstmate:fm-secondmate-task" \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/cmux-task.meta" \
    "backend=cmux" \
    "window=workspace:surface" \
    "worktree=$home/projects/missing-cmux" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '.schema == "fm-fleet-snapshot.v1" and .backlog.present == false and (.tasks|length == 0)' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "cmux-task,scout-task,secondmate-task,ship-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "cmux-task")
    | .backend == "cmux"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "cmux missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    "window=firstmate:fm-active-decision" \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    "window=firstmate:fm-active-blocked" \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    "window=firstmate:fm-stale-decision-ship-task" \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    "window=firstmate:fm-stale-blocked-ship-task" \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=codex" \
    "kind=ship" \
    "mode=ship"
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    "window=firstmate:fm-bold-task" \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | scout | alpha | tmux | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_bearings_schema_surfaces_are_emitted_from_real_fleet_data() {
  local home mate fakebin out
  home=$(make_home bearings-schema)
  mate="$TMP_ROOT/bearings-schema-mate"
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects/child-worktree" "$mate/bin"
  printf 'mate-one\n' > "$mate/.fm-secondmate-home"
  printf '# Firstmate\n' > "$mate/AGENTS.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] main-worker - Main worker (repo: alpha) (kind: ship)
- [ ] main-program - Main program (repo: alpha) (kind: program)
- [ ] main-held - Main held (repo: alpha) (kind: captain) (hold: waiting on operator) (hold-kind: captain)

## Queued
- [ ] main-gate - Main gate blocked-by: done-dependency blocked-by: missing-dependency - waiting (repo: alpha) (kind: ship)

## Done
- [x] done-dependency - Dependency complete (repo: alpha) (kind: ship) (done 2026-07-20)
EOF
  fm_write_meta "$home/state/main-worker.meta" \
    "window=firstmate:fm-main-worker" "worktree=$home/projects/main-worker" \
    "project=alpha" "harness=codex" "kind=ship" "mode=ship"
  mkdir -p "$home/projects/main-worker"
  cat > "$mate/data/backlog.md" <<EOF
## In flight
- [ ] child-worker - Child worker (repo: alpha) (kind: ship)

## Queued
- [ ] child-gate - Child gate blocked-by: child-worker - waiting (repo: alpha) (kind: ship)

## Done
- [x] child-landed - Child landed local main (repo: alpha) (kind: ship) (done 2026-07-21)
EOF
  fm_write_meta "$mate/state/child-worker.meta" \
    "window=firstmate:fm-child-worker-ship-task" "worktree=$mate/projects/child-worktree" \
    "project=alpha" "harness=codex" "kind=ship" "mode=ship"
  printf '%s\n' "- mate-one - delivery (home: $mate; scope: alpha; projects: alpha; added 2026-07-01)" > "$home/data/secondmates.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory == {valid:true,reason:null,orphan_in_flight:[],unstructured_current_count:0}
      and (.backlog.records[] | select(.id == "main-worker")
           | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "main-program")
           | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "main-held")
           | .current_role == "held" and .hold_reason == "waiting on operator"
             and .hold_kind == "captain" and .captain_actionable == false)
      and (.backlog.records[] | select(.id == "main-gate")
           | .blocked_by_ids == ["done-dependency","missing-dependency"]
             and .unresolved_blocker_ids == ["missing-dependency"]
             and .captain_actionable == false)
      and .secondmate_current.total == 1
      and .secondmate_current.records[0].id == "mate-one"
      and .secondmate_current.records[0].provenance.selected == "structured-home"
      and .secondmate_current.records[0].current.state == "active_child_work"
      and .secondmate_current.records[0].queued[0].unresolved_blocker_ids == ["child-worker"]
      and .secondmate_landed.records[0].id == "child-landed"
      and .secondmate_landed.records[0].home_id == "mate-one"
  ' >/dev/null || fail "bearings companion schema surfaces must contain normalized main and secondmate data"
  pass "fleet snapshot emits real normalized bearings companion schema surfaces"
}

test_secondmate_summary_caps_disclose_and_expand() {
  local home fakebin out expanded id bound rc err
  home=$(make_home secondmate-summary-caps)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] active-one - Active one (repo: alpha) (kind: ship)
- [ ] active-two - Active two (repo: alpha) (kind: ship)

## Queued
- [ ] gate-one - Gate one blocked-by: active-one - waiting (repo: alpha) (kind: ship)
- [ ] gate-two - Gate two blocked-by: active-two - waiting (repo: alpha) (kind: ship)

## Done
EOF
  for id in active-one active-two; do
    mkdir -p "$home/projects/$id"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id-ship-task" "worktree=$home/projects/$id" \
      "project=alpha" "harness=codex" "kind=ship" "mode=ship"
    printf 'working: progressing %s\n' "$id" > "$home/state/$id.status"
  done
  for id in decision-one decision-two; do
    mkdir -p "$home/projects/$id"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" "worktree=$home/projects/$id" \
      "project=alpha" "harness=codex" "kind=ship" "mode=ship"
    printf 'needs-decision: choose for %s\n' "$id" > "$home/state/$id.status"
  done
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_SECONDMATE_CHILDREN=1 FM_SNAPSHOT_SECONDMATE_QUEUED=1 \
    FM_SNAPSHOT_SECONDMATE_DECISIONS=1 "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    (.active_children | length) == 1 and .counts.active_children == 2
      and (.decisions_open | length) == 1 and .counts.decisions_open == 2
      and (.holds | length) == 1 and .counts.holds == 2
      and (.queued | length) == 1 and .counts.queued == 2
      and (.endpoints | length) == 1 and .counts.endpoints == 4
      and ([.omitted[] | select(.surface == "active_children showing 1 of 2" and .reveal == "--all-in-flight")] | length) == 1
      and ([.omitted[] | select(.surface == "decisions_open showing 1 of 2" and .reveal == "--all-decisions")] | length) == 1
      and ([.omitted[] | select(.surface == "holds showing 1 of 2" and .reveal == "--all-queued")] | length) == 1
      and ([.omitted[] | select(.surface == "queued showing 1 of 2" and .reveal == "--all-queued")] | length) == 1
      and ([.omitted[] | select(.surface == "endpoints showing 1 of 4" and .reveal == "--all-unhealthy")] | length) == 1
  ' >/dev/null || fail "secondmate summary caps did not disclose every truncated surface: $out"
  expanded=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_SECONDMATE_CHILDREN=0 FM_SNAPSHOT_SECONDMATE_QUEUED=0 \
    FM_SNAPSHOT_SECONDMATE_DECISIONS=0 "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$expanded" | jq -e '
    (.active_children | length) == 2 and (.decisions_open | length) == 2
      and (.holds | length) == 2 and (.queued | length) == 2
      and (.endpoints | length) == 4 and (.omitted | length) == 0
  ' >/dev/null || fail "zero bounds did not reveal complete secondmate summary surfaces: $expanded"
  for bound in FM_SNAPSHOT_SECONDMATES FM_SNAPSHOT_SECONDMATE_CHILDREN \
    FM_SNAPSHOT_SECONDMATE_QUEUED FM_SNAPSHOT_SECONDMATE_DECISIONS \
    FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME
  do
    if err=$(env "$bound=-1" FM_HOME="$home" "$SNAPSHOT" --json 2>&1 >/dev/null); then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 2 ] || fail "$bound negative value must fail before jq"
    assert_contains "$err" "$bound must be 0 or a canonical positive integer (0 means unbounded)" \
      "$bound negative-value diagnostic was unclear"
    if err=$(env "$bound=bad" FM_HOME="$home" "$SNAPSHOT" --json 2>&1 >/dev/null); then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 2 ] || fail "$bound nonnumeric value must fail before jq"
    assert_contains "$err" "$bound must be 0 or a canonical positive integer (0 means unbounded)" \
      "$bound nonnumeric-value diagnostic was unclear"
    for invalid in '' 01
    do
      if err=$(env "$bound=$invalid" FM_HOME="$home" "$SNAPSHOT" --json 2>&1 >/dev/null); then
        rc=0
      else
        rc=$?
      fi
      [ "$rc" -eq 2 ] || fail "$bound value '$invalid' must fail before jq"
      assert_contains "$err" "$bound must be 0 or a canonical positive integer (0 means unbounded)" \
        "$bound value '$invalid' diagnostic was unclear"
    done
  done
  pass "secondmate summary caps disclose truncation, expand at zero, and validate canonical bounds"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane | ship | alpha | tmux | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log | secondmate | $home/secondmate-home | tmux | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    "window=firstmate:fm-dead-secondmate" \
    "project=$home/secondmate-home" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | tmux | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

test_empty_fleet_json
test_fixture_snapshot_json
test_event_hints_follow_reconciled_current_state
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_bearings_schema_surfaces_are_emitted_from_real_fleet_data
test_secondmate_summary_caps_disclose_and_expand
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
