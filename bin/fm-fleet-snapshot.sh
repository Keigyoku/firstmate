#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured fleet snapshot.
#
# Output contract: `--json` prints one object with schema
# `fm-fleet-snapshot.v1`.
# The command is read-only: it does not acquire the session lock, drain wakes,
# arm watchers, mutate backlog state, or write reports.
#
# Top-level fields:
#   schema: stable schema id.
#   fm_home: resolved operational home.
#   roots: resolved root/config/data/state/projects directories.
#   backlog: {path,present,records[]} where records are ordered as written in
#     data/backlog.md and cover In flight, Queued, and Done.
#     Canonical tasks-axi rows are structured; free-form non-empty lines in
#     those sections are preserved as unstructured records.
#   tasks[]: one row per state/<id>.meta, sorted by id.
#     current_state is parsed from bin/fm-crew-state.sh <id> and preserves
#     state, source, detail, and raw line separately.
#     paths.status_log.last_event is historical wake-event data only, never
#     current state.
#     endpoint.exists is the cheap backend endpoint-presence read.
#     endpoint.agent_alive is populated for secondmates only, where it is useful
#     return-channel supervision data; other tasks use "not_checked".
#   scout_reports[]: present data/<id>/report.md pointers.
#   main_inventory: current-backlog consistency checks for the main home.
#   secondmate_current: bounded structured summaries for registered secondmates.
#   secondmate_landed: landed-work roll-up derived from secondmate_current.
#   secondmate_guidance: return-channel action note for renderers and bearings.
#
# Compatibility: JSON is the primary machine-readable surface.
# Human views must render this output instead of parsing state files again.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
BACKLOG="$DATA/backlog.md"
SNAPSHOT_NOW=${FM_SNAPSHOT_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
FM_SNAPSHOT_SECONDMATES=${FM_SNAPSHOT_SECONDMATES-20}
FM_SNAPSHOT_SECONDMATE_CHILDREN=${FM_SNAPSHOT_SECONDMATE_CHILDREN-20}
FM_SNAPSHOT_SECONDMATE_QUEUED=${FM_SNAPSHOT_SECONDMATE_QUEUED-20}
FM_SNAPSHOT_SECONDMATE_DECISIONS=${FM_SNAPSHOT_SECONDMATE_DECISIONS-20}
FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=${FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME-10}
FM_SNAPSHOT_REGISTRY_LINES=${FM_SNAPSHOT_REGISTRY_LINES-2000}
FM_SNAPSHOT_REGISTRY_BYTES=${FM_SNAPSHOT_REGISTRY_BYTES-262144}
FM_SNAPSHOT_REGISTRY_RECORDS=${FM_SNAPSHOT_REGISTRY_RECORDS-200}

for bound_name in \
  FM_SNAPSHOT_SECONDMATES \
  FM_SNAPSHOT_SECONDMATE_CHILDREN \
  FM_SNAPSHOT_SECONDMATE_QUEUED \
  FM_SNAPSHOT_SECONDMATE_DECISIONS \
  FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME \
  FM_SNAPSHOT_REGISTRY_LINES \
  FM_SNAPSHOT_REGISTRY_BYTES \
  FM_SNAPSHOT_REGISTRY_RECORDS
do
  bound_value=${!bound_name}
  case "$bound_value" in
    0|[1-9]|[1-9][0-9]*) ;;
    *)
      echo "fm-fleet-snapshot: $bound_name must be 0 or a canonical positive integer (0 means unbounded)" >&2
      exit 2
      ;;
  esac
done

# shellcheck source=bin/fm-backend.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-ff-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-fleet-snapshot.sh --json
       fm-fleet-snapshot.sh --secondmate-home-summary

Print a read-only structured snapshot of the firstmate fleet.
JSON is the stable machine-readable output contract.
The secondmate home mode emits the local structured summary used by a parent.
EOF
}

OUTPUT_MODE=json
case "${1:---json}" in
  --json) ;;
  --secondmate-home-summary) OUTPUT_MODE=secondmate-home-summary ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-fleet-snapshot: jq not found" >&2; exit 1; }

bool_json() {
  if [ "$1" = 1 ]; then printf 'true'; else printf 'false'; fi
}

path_present_json() {  # <path>
  local present=0
  [ -e "$1" ] && present=1
  jq -n --arg path "$1" --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present}'
}

meta_value() {  # <meta-file> <key>
  fm_meta_get "$1" "$2"
}

last_nonempty_line() {  # <file>
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*$' "$1" 2>/dev/null | tail -1
}

line_verb() {  # <line>
  local v=${1%%:*}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

line_note() {  # <line>
  local n
  case "$1" in
    *:*) n=${1#*:} ;;
    *) n=$1 ;;
  esac
  n="${n#"${n%%[![:space:]]*}"}"
  n="${n%"${n##*[![:space:]]}"}"
  printf '%s' "$n"
}

crew_state_json() {  # <id>
  local id=$1 raw rest state source detail sep
  raw=$(
    FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_HOME="$FM_HOME" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_DATA_OVERRIDE="$DATA" \
      FM_PROJECTS_OVERRIDE="$PROJECTS" \
      FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true
  )
  raw=$(printf '%s\n' "$raw" | head -1)
  sep=' · '
  state=unknown
  source=none
  detail=
  case "$raw" in
    state:\ *"$sep"source:\ *)
      rest=${raw#state: }
      state=${rest%%"$sep"source: *}
      rest=${rest#*"$sep"source: }
      case "$rest" in
        *"$sep"*) source=${rest%%"$sep"*}; detail=${rest#*"$sep"} ;;
        *) source=$rest ;;
      esac
      ;;
  esac
  jq -n --arg raw "$raw" --arg state "$state" --arg source "$source" --arg detail "$detail" \
    '{state:$state,source:$source,detail:$detail,raw:$raw}'
}

status_event_json() {  # <status-log>
  local log=$1 present=0 raw='' verb='' note=''
  if [ -f "$log" ]; then
    present=1
    raw=$(last_nonempty_line "$log" || true)
    verb=$(line_verb "$raw")
    note=$(line_note "$raw")
  fi
  jq -n \
    --arg path "$log" \
    --arg raw "$raw" \
    --arg verb "$verb" \
    --arg note "$note" \
    --argjson present "$(bool_json "$present")" \
    '{path:$path,present:$present,kind:"event_history",last_event:{state:$verb,note:$note,raw:$raw}}'
}

first_pr_url_in_file() {  # <file>
  [ -f "$1" ] || return 1
  grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$1" 2>/dev/null | head -1
}

backlog_json() {
  if [ ! -f "$BACKLOG" ]; then
    jq -n --arg path "$BACKLOG" '{path:$path,present:false,records:[]}'
    return 0
  fi

  # shellcheck disable=SC2094
  jq -Rn --arg path "$BACKLOG" '
    def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def section_state:
      if . == "In flight" then "in_flight"
      elif . == "Queued" then "queued"
      elif . == "Done" then "done"
      else null end;
    def cap($rest; $re):
      (((($rest | capture($re)?) // {}) | .v) // null) as $v
      | if $v == null then null else ($v | trim) end;
    def metadata($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + ":[[:space:]]*(?<v>[^,)]*)");
    def metadata_word($rest; $key):
      cap($rest; ".*(?:\\(|,[[:space:]]*)" + $key + "[[:space:]]+(?<v>[^,)]*)");
    def url_pattern: "https?://[^[:space:])\"<>]+";
    def wrapped_url_pattern: "<?" + url_pattern + ">?";
    def links($rest): [$rest | scan(url_pattern)];
    def strip_trailing_metadata:
      reduce range(0; 20) as $_ (.;
        sub("[[:space:]]*\\([[:space:]]*(?:(?:repo|kind|priority|hold|hold-kind):[[:space:]]*[^)]*|(?:since|merged|reported|done)[[:space:]]+[^)]*)[[:space:]]*\\)[[:space:]]*$"; ""));
    def strip_title_artifacts:
      sub("[[:space:]]+-[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+data/[^[:space:])]+/report\\.md$"; "")
      | sub("[[:space:]]+-[[:space:]]+local main$"; "")
      | sub("[[:space:]]+local main$"; "")
      | sub("[[:space:]]+-[[:space:]]*$"; "");
    def clean_title:
      strip_trailing_metadata
      | strip_title_artifacts
      | gsub("[[:space:]]+"; " ")
      | trim;
    def title_of($rest):
      $rest
      | gsub(wrapped_url_pattern; "")
      | sub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:])]+[[:space:]]+-[[:space:]]+.*$"; "")
      | gsub("[[:space:]]*blocked-by:[[:space:]]+[^[:space:]]+"; "")
      | clean_title;
    def blocked_by_ids($rest):
      [ $rest | scan("blocked-by:[[:space:]]+(?<id>[^[:space:])]+)") | .[0] ]
      | reduce .[] as $id ([]; if index($id) == null then . + [$id] else . end);
    def blocked_reason($rest):
      cap($rest; ".*blocked-by:[[:space:]]*[^[:space:])]+[[:space:]]+-[[:space:]]*(?<v>.*)$") as $reason
      | if $reason == null then null
        else ($reason | clean_title | if . == "" then null else . end)
        end;
    def local_note($rest):
      cap(($rest | strip_trailing_metadata); ".*(?:^|[[:space:]]+-[[:space:]]+|[[:space:]])(?<v>local main)$");
    def completion($rest):
      (metadata_word($rest; "merged")) as $merged
      | (metadata_word($rest; "reported")) as $reported
      | (metadata_word($rest; "done")) as $done
      | if $merged != null then {verb:"merged",date:$merged}
        elif $reported != null then {verb:"reported",date:$reported}
        elif $done != null then {verb:"done",date:$done}
        else {verb:null,date:null} end;
    def row_match($line):
      (($line | capture("^[-*][[:space:]]+\\[(?<check>[ xX])\\][[:space:]]+(?<id>[^[:space:]]+)[[:space:]]+-[[:space:]]+(?<rest>.*)$")?) //
       (($line | capture("^[-*][[:space:]]+\\*\\*(?<id>[^*]+)\\*\\*[[:space:]]+-[[:space:]]+(?<rest>.*)$")?)
        | if . == null then null else . + {check:" "} end));
    def structured_row($line):
      ($line | test("^[-*][[:space:]]+\\[[ xX]\\][[:space:]]+[^[:space:]]+[[:space:]]+-[[:space:]]+"))
      or ($line | test("^[-*][[:space:]]+\\*\\*[^*]+\\*\\*[[:space:]]+-[[:space:]]+"));
    def parse_row($line; $section; $order):
      row_match($line) as $m
      | if $m == null then
          {order:$order,state:$section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}
        else
          ($m.rest) as $rest
          | {order:$order,
             state:$section,
             structured:true,
             id:($m.id | trim),
             checked:($m.check | test("[xX]")),
             title:title_of($rest),
             repo:metadata($rest; "repo"),
             kind:metadata($rest; "kind"),
             priority:metadata($rest; "priority"),
             hold_reason:metadata($rest; "hold"),
             hold_kind:metadata($rest; "hold-kind"),
             blocked_by:cap($rest; ".*blocked-by:[[:space:]]*(?<v>[^[:space:])]+).*"),
             blocked_by_ids:blocked_by_ids($rest),
             blocked_reason:blocked_reason($rest),
             since:metadata_word($rest; "since"),
             merged:metadata_word($rest; "merged"),
             reported:metadata_word($rest; "reported"),
             done:metadata_word($rest; "done"),
             completion:completion($rest),
             links:links($rest),
             pr_url:((links($rest) | map(select(test("/pull/[0-9]+"))) | .[0]) // null),
             report_path:cap($rest; ".*(?<v>data/[^[:space:])]+/report\\.md).*"),
             local_note:local_note($rest),
             raw:$line,
             body_lines:[],
             body_excerpt:null}
        end;
    reduce inputs as $line
      ({path:$path,present:true,records:[],section:null,order:0};
       if ($line | test("^##[[:space:]]+")) then
         .section = (($line | sub("^##[[:space:]]+";"") | trim) | section_state)
       elif .section == null or ($line | trim) == "" then
         .
       elif structured_row($line) then
         .order += 1
         | .records += [parse_row($line; .section; .order)]
       elif ((.records | length) > 0 and (.records[-1].structured == true) and ($line | test("^[[:space:]]+"))) then
         ($line | trim) as $body
         | if $body == "" then .
           else .records[-1].body_lines += [$body] end
       else
         .order += 1
         | .records += [{order:.order,state:.section,structured:false,id:null,raw:$line,body_lines:[],body_excerpt:null}]
       end)
    | .records |= map(
        if (.body_lines | length) > 0 then
          .body_excerpt = ((.body_lines | join(" "))[:240])
        else . end)
    | .records as $records
    | (reduce ($records[] | select(.structured)) as $record ({};
         .[$record.id] = ((.[$record.id] // true) and ($record.state == "done")))) as $resolved_ids
    | .records |= map(
        if .structured then
          . as $record
          | .unresolved_blocker_ids = [
              $record.blocked_by_ids[] as $blocker
              | select($resolved_ids[$blocker] != true)
              | $blocker
            ]
          | .current_role =
              (if .state == "in_flight" and .hold_reason != null and .hold_kind != null then "held"
               elif .state == "in_flight" and .kind == "program" then "program"
               elif .state == "in_flight" then "worker"
               elif .state == "queued" then "queued"
               else "done" end)
          | .requires_child_metadata = (.current_role == "worker")
          | .captain_actionable = false
        else . end)
    | del(.section,.order)
  ' < "$BACKLOG"
}

task_json_lines() {
  local meta id kind harness mode yolo project worktree home projects backend target status_log report_path
  local pr pr_source event_json current_json endpoint_exists agent_alive meta_json status_json report_json worktree_json home_json
  local last_event_raw last_event_verb current_state pending_decision blocked_event report_present=0 pr_from_status

  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    kind=$(meta_value "$meta" kind)
    [ -n "$kind" ] || kind=ship
    harness=$(meta_value "$meta" harness)
    mode=$(meta_value "$meta" mode)
    yolo=$(meta_value "$meta" yolo)
    project=$(meta_value "$meta" project)
    worktree=$(meta_value "$meta" worktree)
    home=$(meta_value "$meta" home)
    projects=$(meta_value "$meta" projects)
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    status_log="$STATE/$id.status"
    report_path="$DATA/$id/report.md"
    pr=$(meta_value "$meta" pr)
    pr_source=meta
    if [ -z "$pr" ]; then
      pr_from_status=$(first_pr_url_in_file "$status_log" || true)
      pr=$pr_from_status
      pr_source=status_event
    fi
    if [ -z "$pr" ]; then
      pr_source=absent
    fi

    current_json=$(crew_state_json "$id")
    event_json=$(status_event_json "$status_log")
    last_event_raw=$(printf '%s' "$event_json" | jq -r '.last_event.raw // ""')
    last_event_verb=$(printf '%s' "$event_json" | jq -r '.last_event.state // ""')
    current_state=$(printf '%s' "$current_json" | jq -r '.state // ""')
    pending_decision=0
    blocked_event=0
    [ "$last_event_verb" = needs-decision ] && [ "$current_state" = parked ] && pending_decision=1
    [ "$last_event_verb" = blocked ] && [ "$current_state" = blocked ] && blocked_event=1

    endpoint_exists=null
    if [ -n "$target" ]; then
      if fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
        endpoint_exists=true
      else
        endpoint_exists=false
      fi
    fi
    agent_alive=not_checked
    if [ "$kind" = secondmate ] && [ -n "$target" ]; then
      agent_alive=$(fm_backend_agent_alive "$backend" "$target" 2>/dev/null || printf unknown)
    fi

    [ -f "$report_path" ] && report_present=1 || report_present=0
    meta_json=$(path_present_json "$meta")
    status_json=$event_json
    report_json=$(path_present_json "$report_path")
    if [ -n "$worktree" ]; then worktree_json=$(path_present_json "$worktree"); else worktree_json=$(jq -n '{path:null,present:false}'); fi
    if [ -n "$home" ]; then home_json=$(path_present_json "$home"); else home_json=$(jq -n '{path:null,present:false}'); fi

    jq -n \
      --arg id "$id" \
      --arg kind "$kind" \
      --arg harness "$harness" \
      --arg mode "$mode" \
      --arg yolo "$yolo" \
      --arg project "$project" \
      --arg worktree "$worktree" \
      --arg home "$home" \
      --arg projects "$projects" \
      --arg backend "$backend" \
      --arg target "$target" \
      --arg pr "$pr" \
      --arg pr_source "$pr_source" \
      --arg agent_alive "$agent_alive" \
      --arg last_event_raw "$last_event_raw" \
      --argjson current_state "$current_json" \
      --argjson meta_path "$meta_json" \
      --argjson status_log "$status_json" \
      --argjson report "$report_json" \
      --argjson worktree_path "$worktree_json" \
      --argjson home_path "$home_json" \
      --argjson endpoint_exists "$endpoint_exists" \
      --argjson pending_decision "$(bool_json "$pending_decision")" \
      --argjson blocked_event "$(bool_json "$blocked_event")" \
      --argjson report_present "$(bool_json "$report_present")" \
      '{
        id:$id,
        kind:$kind,
        harness:($harness // ""),
        mode:($mode // ""),
        yolo:($yolo // ""),
        project:($project // ""),
        backend:$backend,
        paths:{
          meta:$meta_path,
          status_log:$status_log,
          worktree:$worktree_path,
          home:$home_path,
          report:$report
        },
        secondmate_projects:($projects | if . == "" then [] else split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(. != "")) end),
        current_state:$current_state,
        endpoint:{target:($target | if . == "" then null else . end),exists:$endpoint_exists,agent_alive:$agent_alive},
        pr:{url:($pr | if . == "" then null else . end),source:$pr_source},
        hints:{
          pending_decision:$pending_decision,
          blocked_event:$blocked_event,
          scout_report_present:$report_present,
          last_event_text:$last_event_raw
        },
        actions:(
          if $kind == "secondmate" then
            {send:"bin/fm-send.sh fm-\($id) \u0027<request>\u0027",
             watch:"read status/doc return channel; do not routinely fm-peek a secondmate for answers",
             return_channel_note:"Secondmate answers come back through status/doc paths after a marked fm-send request."}
          else
            {watch:"bin/fm-peek.sh fm-\($id)",
             steer:"bin/fm-send.sh fm-\($id) \u0027<instruction>\u0027",
             return_channel_note:null}
          end)
      }'
  done | jq -s 'sort_by(.id)'
}

main_inventory_json() {  # <backlog-json> <tasks-json>
  jq -n --argjson backlog "$1" --argjson tasks "$2" '
    ([ $backlog.records[]?
       | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured
    | ([ $backlog.records[]?
         | select(.state == "in_flight" and .structured and .requires_child_metadata) ]) as $owned
    | ([ $owned[] | select(.id as $id | [$tasks[].id] | index($id) | not) | .id ]) as $orphans
    | {valid:(($unstructured | length) == 0 and ($orphans | length) == 0),
       reason:(if ($unstructured | length) > 0 then "unstructured current backlog row"
               elif ($orphans | length) > 0 then "in-flight backlog item has no child metadata"
               else null end),
       orphan_in_flight:$orphans,
       unstructured_current_count:($unstructured | length)}'
}

secondmate_home_summary_json() {  # <backlog-json> <tasks-json>
  jq -n \
    --arg generated "$SNAPSHOT_NOW" \
    --arg home "$FM_HOME" \
    --argjson child_n "$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
    --argjson queued_n "$FM_SNAPSHOT_SECONDMATE_QUEUED" \
    --argjson decisions_n "$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
    --argjson landed_n "$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
    --argjson backlog "$1" \
    --argjson tasks "$2" '
    def trunc($n): tostring | gsub("\\s+"; " ") | if length > $n then .[:$n] + "…" else . end;
    def bounded($rows; $n): if $n == 0 then $rows else $rows[:$n] end;
    def omission($surface; $rows; $n; $reveal):
      if $n > 0 and ($rows | length) > $n
      then {surface:("\($surface) showing \($n) of \($rows | length)"),reveal:$reveal}
      else empty end;
    ([ $backlog.records[]? | select(.state == "in_flight" and .structured) ]) as $in_flight
    | ([ $backlog.records[]?
         | select(.structured and
             (.state == "queued" or
              (.state == "in_flight" and .current_role == "held"
               and (.id as $id | any($tasks[]; .id == $id and .current_state.state == "working") | not)))) ]) as $queued
    | ([ $in_flight[] | select(.requires_child_metadata)
         | select(.id as $id | [$tasks[].id] | index($id) | not) | .id ]) as $orphans
    | ([ $backlog.records[]?
         | select((.state == "in_flight" or .state == "queued") and (.structured | not)) ]) as $unstructured
    | ([ $in_flight[] as $work | $tasks[]
         | select(.id == $work.id and .current_state.state == "working" and $work.current_role != "program")
         | {id,kind,state:.current_state.state,source:.current_state.source,
            doing:((.current_state.detail // "") | trunc(120))} ]) as $active
    | ([ $queued[]
         | select(.kind == "captain" and .hold_kind == "captain" and .hold_reason != null)
         | {id,key:.id,verb:"captain-hold",summary:(.title | trunc(160)),
            reason:(.hold_reason | trunc(160)),source:"backlog"} ]) as $captain_holds
    | ([ $tasks[]
         | if .hints.pending_decision == true then
             {id,key:.id,verb:"needs-decision",summary:((.hints.last_event_text // "needs decision") | trunc(160)),reason:null,source:"status"}
           elif .hints.blocked_event == true then
             {id,key:.id,verb:"blocked",summary:((.hints.last_event_text // "blocked") | trunc(160)),reason:null,source:"status"}
           else empty end ]) as $status_decisions
    | ($captain_holds + $status_decisions) as $decisions
    | ([ $queued[]
         | select((.kind == "captain" and .hold_kind == "captain" and .hold_reason != null) | not)
         | select((.unresolved_blocker_ids | length) > 0 or .hold_reason != null)
         | {id,title:(.title | trunc(90)),blocked_by:(.unresolved_blocker_ids | join(",")),
            blocked_by_ids:.blocked_by_ids,unresolved_blocker_ids:.unresolved_blocker_ids,
            reason:((.hold_reason // .blocked_reason // "blocked") | trunc(120)),source:"backlog"} ]) as $holds
    | ([ $backlog.records[]? | select(.state == "done" and .structured and .kind != "captain")
         | {id:(.id | trunc(120)),title:(.title | trunc(120)),pr_url,report_path,local_note,completion} ]
       | sort_by([(.completion.date // ""),.id]) | reverse) as $landed
    | ([ $queued[] | {id:(.id | trunc(120)),title:(.title | trunc(120)),blocked_by,
         blocked_by_ids,unresolved_blocker_ids,blocked_reason,hold_reason,hold_kind,captain_actionable,repo,kind}]) as $queued_rows
    | ([ $tasks[] | {id,state:.current_state.state,source:.current_state.source,endpoint}]) as $endpoints
    | (($backlog.present == true) and (($unstructured | length) == 0) and (($orphans | length) == 0)) as $valid
    | (if ($unstructured | length) > 0 then "unstructured current backlog row"
       elif ($orphans | length) > 0 then "in-flight backlog item has no child metadata"
       elif $backlog.present != true then "missing structured backlog"
       else null end) as $reason
    | {schema:"fm-secondmate-home-summary.v1",generated:$generated,home:$home,valid:$valid,reason:$reason,
       state:(if $valid | not then "unknown" elif ($decisions | length) > 0 then "captain_decision"
              elif ($active | length) > 0 then "active_child_work"
              elif ($holds | length) > 0 then "externally_held" else "no_active_work" end),
       active_children:bounded($active;$child_n),decisions_open:bounded($decisions;$decisions_n),
       holds:bounded($holds;$queued_n),queued:bounded($queued_rows;$queued_n),
       landed:bounded($landed;$landed_n),endpoints:bounded($endpoints;$child_n),
       counts:{active_children:($active|length),decisions_open:($decisions|length),holds:($holds|length),
         queued:($queued|length),landed:($landed|length),endpoints:($tasks|length)},
       omitted:[
         omission("active_children";$active;$child_n;"--all-in-flight"),
         omission("decisions_open";$decisions;$decisions_n;"--all-decisions"),
         omission("holds";$holds;$queued_n;"--all-queued"),
         omission("queued";$queued_rows;$queued_n;"--all-queued"),
         omission("endpoints";$endpoints;$child_n;"--all-unhealthy")
       ]}'
}

registry_secondmates_json() {
  local registry="$DATA/secondmates.md" input='' read_rc=0 input_truncated=0
  local line_count byte_count LC_ALL=C
  if [ ! -e "$registry" ]; then
    jq -n --arg path "$registry" '{present:false,available:true,reason:null,provenance:"registered-table",path:$path,records:[],input_truncated:false,records_truncated:false}'
    return 0
  fi
  if [ ! -f "$registry" ]; then
    jq -n --arg path "$registry" '{present:true,available:false,reason:"registry path is not a regular file",provenance:"registered-table",path:$path,records:[],input_truncated:false,records_truncated:false}'
    return 0
  fi
  if [ ! -r "$registry" ]; then
    jq -n --arg path "$registry" '{present:true,available:false,reason:"registry file is not readable",provenance:"registered-table",path:$path,records:[],input_truncated:false,records_truncated:false}'
    return 0
  fi
  if [ "$FM_SNAPSHOT_REGISTRY_BYTES" -gt 0 ]; then
    input=$({ head -c "$((FM_SNAPSHOT_REGISTRY_BYTES + 1))" -- "$registry" 2>/dev/null; printf '\034%s' "$?"; })
    read_rc=${input##*$'\034'}
    input=${input%$'\034'*}
    if [ "$read_rc" -eq 0 ]; then
      byte_count=${#input}
      if [ "$byte_count" -gt "$FM_SNAPSHOT_REGISTRY_BYTES" ]; then
        input=${input:0:FM_SNAPSHOT_REGISTRY_BYTES}
        case "$input" in
          *$'\n') ;;
          *$'\n'*) input=${input%$'\n'*} ;;
          *) input='' ;;
        esac
        input_truncated=1
      fi
    fi
  elif [ "$FM_SNAPSHOT_REGISTRY_LINES" -gt 0 ]; then
    input=$({ head -n "$((FM_SNAPSHOT_REGISTRY_LINES + 1))" -- "$registry" 2>/dev/null; printf '\034%s' "$?"; })
    read_rc=${input##*$'\034'}
    input=${input%$'\034'*}
  else
    input=$({ cat -- "$registry" 2>/dev/null; printf '\034%s' "$?"; })
    read_rc=${input##*$'\034'}
    input=${input%$'\034'*}
  fi
  if [ "$read_rc" -ne 0 ]; then
    jq -n --arg path "$registry" --arg reason "registry read failed (exit $read_rc)" \
      '{present:true,available:false,reason:$reason,provenance:"registered-table",path:$path,records:[],input_truncated:false,records_truncated:false}'
    return 0
  fi
  if [ "$FM_SNAPSHOT_REGISTRY_LINES" -gt 0 ]; then
    line_count=$(printf '%s' "$input" | awk 'END { print NR }')
    if [ "$line_count" -gt "$FM_SNAPSHOT_REGISTRY_LINES" ]; then
      input=$(printf '%s' "$input" | awk -v limit="$FM_SNAPSHOT_REGISTRY_LINES" 'NR <= limit')
      input_truncated=1
    fi
  fi
  printf '%s\n' "$input" | jq -Rn \
    --arg path "$registry" \
    --argjson input_truncated "$(bool_json "$input_truncated")" \
    --argjson record_limit "$FM_SNAPSHOT_REGISTRY_RECORDS" '
    ([ inputs | select(startswith("- "))
      | (capture("^- (?<id>[^[:space:]]+)")?) as $id
      | (capture("\\(home:[[:space:]]*(?<home>[^;)]*)[;)]")?) as $home
      | select($id != null)
      | {id:$id.id,home:($home.home // null)} ]) as $parsed
    | {present:true,available:true,reason:null,provenance:"registered-table",path:$path,
       records:(if $record_limit == 0 then $parsed else $parsed[:$record_limit] end),
       input_truncated:$input_truncated,
       records_truncated:($record_limit > 0 and ($parsed | length) > $record_limit)}'
}

secondmate_current_json() {
  local registry records total shown id home summary reason record
  registry=$(registry_secondmates_json) || return 1
  records='[]'
  total=$(printf '%s' "$registry" | jq '.records | length')
  shown=$total
  if [ "$FM_SNAPSHOT_SECONDMATES" -gt 0 ] && [ "$shown" -gt "$FM_SNAPSHOT_SECONDMATES" ]; then
    shown=$FM_SNAPSHOT_SECONDMATES
  fi
  while IFS=$'\t' read -r id home; do
    [ -n "$id" ] || continue
    reason=
    summary=
    if [ -z "$home" ]; then
      reason="registry entry has no home"
    elif validate_secondmate_home "$id" "$home"; then
      home=$VALIDATED_HOME
      summary=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
        FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$home" FM_SNAPSHOT_NOW="$SNAPSHOT_NOW" \
        FM_SNAPSHOT_SECONDMATE_CHILDREN="$FM_SNAPSHOT_SECONDMATE_CHILDREN" \
        FM_SNAPSHOT_SECONDMATE_QUEUED="$FM_SNAPSHOT_SECONDMATE_QUEUED" \
        FM_SNAPSHOT_SECONDMATE_DECISIONS="$FM_SNAPSHOT_SECONDMATE_DECISIONS" \
        FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME="$FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME" \
        "$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary 2>/dev/null) || reason="structured home summary failed"
    else
      reason=$VALIDATION_ERROR
    fi
    if [ -n "$summary" ] && printf '%s' "$summary" | jq -e '.schema == "fm-secondmate-home-summary.v1"' >/dev/null 2>&1; then
      record=$(jq -n --arg id "$id" --arg home "$home" --arg observed "$SNAPSHOT_NOW" --argjson summary "$summary" '
        {id:$id,home:$home,registered:true,current:{state:$summary.state,reason:$summary.reason},
         active_children:$summary.active_children,decisions_open:$summary.decisions_open,holds:$summary.holds,
         queued:$summary.queued,landed:$summary.landed,endpoints:$summary.endpoints,counts:$summary.counts,omitted:$summary.omitted,
         provenance:{selected:"structured-home"},freshness:{status:"fresh",observed_at:$observed,age_seconds:0},
         contradiction:false,parent_event:{activity_scan:{available:true,input_truncated:false,retained_truncated:false}}}')
    else
      record=$(jq -n --arg id "$id" --arg home "$home" --arg reason "${reason:-structured home summary unavailable}" --arg observed "$SNAPSHOT_NOW" '
        {id:$id,home:($home | if . == "" then null else . end),registered:true,
         current:{state:"unknown",reason:$reason},active_children:[],decisions_open:[],holds:[],queued:[],landed:[],endpoints:[],
         counts:{active_children:0,decisions_open:0,holds:0,queued:0,landed:0,endpoints:0},omitted:[],
         provenance:{selected:"registered-table"},freshness:{status:"unavailable",observed_at:$observed,age_seconds:null},
         contradiction:false,parent_event:{activity_scan:{available:false,input_truncated:false,retained_truncated:false}}}')
    fi
    records=$(jq -n --argjson records "$records" --argjson record "$record" '$records + [$record]')
  done < <(printf '%s' "$registry" | jq -r --argjson shown "$shown" '.records[:$shown][] | [.id,(.home // "")] | @tsv')
  jq -n --argjson registry "$registry" --argjson records "$records" --argjson total "$total" --argjson shown "$shown" \
    '{registry:$registry,records:$records,total:$total,shown:$shown,truncated:($total-$shown)}'
}

secondmate_landed_from_current_json() {
  jq -n --argjson current "$1" '
    {records:[ $current.records[] | select(.provenance.selected == "structured-home") as $mate
      | $mate.landed[] | . + {home:$mate.home,home_id:$mate.id}],
     truncated:[ $current.records[] | select(.provenance.selected == "structured-home" and .counts.landed > (.landed|length)) | .home],
     unreadable:[ $current.records[] | select(.provenance.selected != "structured-home") | .home // ("<" + .id + ": unavailable>")],
     partial:[ $current.records[] | select(.provenance.selected == "structured-home" and .current.state == "unknown") | .home]}
    | .records |= sort_by([(.completion.date // ""),.id]) | .records |= reverse'
}

scout_report_lines() {
  local report id
  if [ ! -d "$DATA" ]; then
    jq -n '[]'
    return 0
  fi
  LC_ALL=C find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md -print \
    | sort \
    | while IFS= read -r report; do
      id=$(basename "$(dirname "$report")")
      jq -n --arg id "$id" --arg path "$report" '{id:$id,path:$path}'
    done \
    | jq -s 'sort_by(.id)'
}

BACKLOG_JSON=$(backlog_json)
TASKS_JSON=$(task_json_lines)

if [ "$OUTPUT_MODE" = secondmate-home-summary ]; then
  secondmate_home_summary_json "$BACKLOG_JSON" "$TASKS_JSON"
  exit $?
fi

SCOUT_REPORTS_JSON=$(scout_report_lines)
MAIN_INVENTORY_JSON=$(main_inventory_json "$BACKLOG_JSON" "$TASKS_JSON")
SECONDMATE_CURRENT_JSON=$(secondmate_current_json)
SECONDMATE_LANDED_JSON=$(secondmate_landed_from_current_json "$SECONDMATE_CURRENT_JSON")

jq -n \
  --arg generated "$SNAPSHOT_NOW" \
  --arg fm_home "$FM_HOME" \
  --arg fm_root "$FM_ROOT" \
  --arg state "$STATE" \
  --arg data "$DATA" \
  --arg config "$CONFIG" \
  --arg projects "$PROJECTS" \
  --argjson backlog "$BACKLOG_JSON" \
  --argjson tasks "$TASKS_JSON" \
  --argjson main_inventory "$MAIN_INVENTORY_JSON" \
  --argjson scout_reports "$SCOUT_REPORTS_JSON" \
  --argjson secondmate_current "$SECONDMATE_CURRENT_JSON" \
  --argjson secondmate_landed "$SECONDMATE_LANDED_JSON" \
  'def backlog_by_id($id): ($backlog.records[]? | select(.structured == true and .id == $id) | .) // null;
   def task_by_id($id): ($tasks[]? | select(.id == $id) | .) // null;
   def report_kind($id): (task_by_id($id).kind // backlog_by_id($id).kind // "scout");
   {
     schema:"fm-fleet-snapshot.v1",
     generated:$generated,
     fm_home:$fm_home,
     roots:{fm_root:$fm_root,state:$state,data:$data,config:$config,projects:$projects},
     backlog:$backlog,
     tasks:($tasks | map(. + {backlog:backlog_by_id(.id)})),
     main_inventory:$main_inventory,
     scout_reports:($scout_reports | map(. + {kind:report_kind(.id)})),
     secondmate_current:$secondmate_current,
     secondmate_landed:$secondmate_landed,
     secondmate_guidance:{
       note:"For kind=secondmate, send marked supervisor requests with fm-send and read the status/doc return channel; do not routinely fm-peek the secondmate chat for answers."
     }
   }'
