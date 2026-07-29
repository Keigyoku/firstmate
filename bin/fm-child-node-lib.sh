#!/usr/bin/env bash
# Child Node producer helpers (CN-P).
# Source this file.
# Mutable descriptors and current-state publication reuse the resident atomic-JSON
# write seam; immutable provision creation adds an exclusive no-clobber publish.
#
# Paths under the Crew Lead home (captain lock Q-CN1):
#   crews/<task-id>/.child-node/{contract,provision,child}.json
#   crews/<task-id>/state/child-current.json
#
# Idempotency contract (never clobber a live identity):
#   - contract.json: written only when absent; validated, never force-rewritten
#   - provision.json: immutable once it matches the complete provision shape below
#   - child.json: static descriptor may be rewritten (template metadata)
#   - child-current.json: atomic publish; epoch is monotonic for matching container_id
#
# Provision shape is ONE definition (fm_child_node_provision_shape_jq /
# fm_child_node_provision_valid). A document is either the shape or it is not.
# Do not accumulate field-by-field keep checks beside this predicate.

# shellcheck source=bin/fm-resident-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-resident-lib.sh"

# Authoritative complete Child Node provision document predicate (jq).
# shellcheck disable=SC2016
fm_child_node_provision_shape_jq='
  .schema == "dev.vellum.child-node.provision/1"
  and (.container_id | type == "string")
  and (.container_id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"))
  and (.created_at | type == "string")
  and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and .identity_kind == "child-container"
'

fm_child_node_home() {  # <fm-home> <task-id>
  printf '%s/crews/%s\n' "$1" "$2"
}

fm_child_node_capability_tokens() {
  printf '%s\n' \
    lifecycle.status-v1 \
    backend.herdr-v1 \
    transcript.bind-v1 \
    input.backend-v1
}

fm_child_node_type_for_kind() {  # <kind>
  case "$1" in
    secondmate) printf '%s\n' firstmate-secondmate ;;
    scout) printf '%s\n' firstmate-scout ;;
    ship|*) printf '%s\n' firstmate-crew ;;
  esac
}

# True only when path is the complete documented provision shape.
fm_child_node_provision_valid() {  # <provision.json path>
  local path=$1 created_at parsed_at
  [ -f "$path" ] || return 1
  jq -e "$fm_child_node_provision_shape_jq" "$path" >/dev/null 2>&1 || return 1
  created_at=$(jq -er '.created_at' "$path") || return 1
  parsed_at=$(date -u -d "$created_at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
    || parsed_at=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$created_at" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) \
    || return 1
  [ "$parsed_at" = "$created_at" ]
}

fm_child_node_container_id() {  # <child-home>
  local provision=$1/.child-node/provision.json
  fm_child_node_provision_valid "$provision" || return 1
  jq -er '.container_id' "$provision"
}

fm_child_node_uuid_v4() {
  local id
  if command -v uuidgen >/dev/null 2>&1; then
    id=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    id=$(cat /proc/sys/kernel/random/uuid)
  else
    return 1
  fi
  printf '%s\n' "$id"
}

fm_child_node_exclusive_json() {  # <destination>
  local destination=$1 directory temporary
  [ ! -d "$destination" ] || return 1
  directory=$(dirname "$destination")
  mkdir -p "$directory"
  temporary=$(mktemp "$directory/.$(basename "$destination").tmp.XXXXXX") || return 1
  if ! jq -e . > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  if command -v sync >/dev/null 2>&1; then
    sync -f "$temporary" 2>/dev/null || sync 2>/dev/null || true
  fi
  if ! ln "$temporary" "$destination" 2>/dev/null; then
    rm -f "$temporary"
    return 1
  fi
  rm -f "$temporary"
  if command -v sync >/dev/null 2>&1; then
    sync -f "$directory" 2>/dev/null || true
  fi
}

# Standalone UUID-v4 check for non-provision ids (for example, the parent God Node id).
# Child provision identity validation goes only through fm_child_node_provision_valid.
fm_child_node_valid_uuid_v4() {  # <id>
  [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}
