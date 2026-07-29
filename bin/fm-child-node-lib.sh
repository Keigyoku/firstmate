#!/usr/bin/env bash
# Child Node producer helpers (CN-P).
# Source this file. Reuses the resident atomic-JSON write seam so birth and
# publish share one rename-into-place pattern with Crew Lead setup.
#
# Paths under the Crew Lead home (captain lock Q-CN1):
#   crews/<task-id>/.child-node/{contract,provision,child}.json
#   crews/<task-id>/state/child-current.json
#
# Idempotency contract (never clobber a live identity):
#   - contract.json: written only when absent; validated, never force-rewritten
#   - provision.json: immutable once a valid UUID-v4 container_id is present
#   - child.json: static descriptor may be rewritten (template metadata)
#   - child-current.json: atomic publish; epoch is monotonic for matching container_id

# shellcheck source=bin/fm-resident-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-resident-lib.sh"

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

fm_child_node_container_id() {  # <child-home>
  jq -er 'select(.schema == "dev.vellum.child-node.provision/1") | .container_id' \
    "$1/.child-node/provision.json"
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

fm_child_node_valid_uuid_v4() {  # <id>
  case "$1" in
    ????????-????-4???-[89ab]???-????????????) return 0 ;;
    *) return 1 ;;
  esac
}
