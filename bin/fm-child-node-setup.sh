#!/usr/bin/env bash
# Provision a Child Node home under the Crew Lead home (CN-P birth docs).
# Usage: fm-child-node-setup.sh <task-id> [--kind ship|scout|secondmate]
#
# Writes crews/<task-id>/.child-node/{contract,provision,child}.json.
# Parent link is the God Node provision container_id (durable), never a god:
# session wire id alone.
#
# Idempotent: a valid provision.container_id is never replaced (respawn / recovery
# keep identity). contract.json is written only when absent. child.json is the
# static descriptor and may be rewritten like resident.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${GOD_NODE_HOME:-${RESIDENT_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}}"
CHILD_VERSION="dev.vellum.firstmate-child/1"

# shellcheck source=bin/fm-child-node-lib.sh
. "$SCRIPT_DIR/fm-child-node-lib.sh"

usage() {
  sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

TASK_ID=
KIND=ship
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --kind) KIND=${2:-}; shift 2 ;;
    --kind=*) KIND=${1#--kind=}; shift ;;
    -*)
      echo "fm-child-node-setup: unknown flag: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$TASK_ID" ]; then
        TASK_ID=$1
        shift
      else
        echo "fm-child-node-setup: unexpected argument: $1" >&2
        exit 2
      fi
      ;;
  esac
done

[ -n "$TASK_ID" ] || { echo "usage: fm-child-node-setup.sh <task-id> [--kind ship|scout|secondmate]" >&2; exit 2; }
case "$KIND" in
  ship|scout|secondmate) ;;
  *) echo "fm-child-node-setup: --kind must be ship, scout, or secondmate" >&2; exit 2 ;;
esac
case "$TASK_ID" in
  */*|*..*|"") echo "fm-child-node-setup: invalid task id: $TASK_ID" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "fm-child-node-setup: jq is required" >&2; exit 1; }

# Parent God Node provision is required for the durable parent link.
if [ ! -s "$FM_HOME/.god-node/provision.json" ]; then
  "$SCRIPT_DIR/fm-resident-setup.sh"
fi
PARENT_ID=$(fm_resident_container_id "$FM_HOME") || {
  echo "fm-child-node-setup: parent God Node provision is missing or unreadable" >&2
  exit 1
}
fm_child_node_valid_uuid_v4 "$PARENT_ID" || {
  echo "fm-child-node-setup: parent container_id is not a UUID-v4" >&2
  exit 1
}

CHILD_HOME=$(fm_child_node_home "$FM_HOME" "$TASK_ID")
CONTRACT_DIR="$CHILD_HOME/.child-node"
CONTRACT="$CONTRACT_DIR/contract.json"
PROVISION="$CONTRACT_DIR/provision.json"
CHILD="$CONTRACT_DIR/child.json"
mkdir -p "$CONTRACT_DIR" "$CHILD_HOME/state"

if [ ! -e "$CONTRACT" ]; then
  jq -n \
    '{schema:"dev.vellum.child-node/1",minimum_reader:1}' \
    | fm_resident_atomic_json "$CONTRACT"
fi

if ! jq -e '.schema == "dev.vellum.child-node/1" and .minimum_reader == 1 and has("container_id") == false and has("created_at") == false and has("identity_kind") == false' "$CONTRACT" >/dev/null; then
  echo "fm-child-node-setup: contract.json must carry only schema and minimum_reader" >&2
  exit 1
fi

# Keep only a complete provision shape (fm_child_node_provision_valid). Half-formed
# documents with a string container_id but missing created_at/identity_kind are NOT
# valid identities — refuse rather than preserve-and-publish them as valid.
if ! fm_child_node_provision_valid "$PROVISION"; then
  # Refuse to replace a present but invalid provision document: that would clobber
  # operator-owned content. Only create when missing.
  if [ -e "$PROVISION" ]; then
    echo "fm-child-node-setup: provision.json exists but is not a valid child-node provision; refusing to overwrite" >&2
    exit 1
  fi
  CONTAINER_ID=$(fm_child_node_uuid_v4) || {
    echo "fm-child-node-setup: uuidgen or /proc/sys/kernel/random/uuid is required" >&2
    exit 1
  }
  CREATED_AT=$(fm_resident_rfc3339)
  jq -n \
    --arg container_id "$CONTAINER_ID" \
    --arg created_at "$CREATED_AT" \
    '{schema:"dev.vellum.child-node.provision/1",container_id:$container_id,created_at:$created_at,identity_kind:"child-container"}' \
    | fm_child_node_exclusive_json "$PROVISION" \
    || {
      if [ ! -e "$PROVISION" ]; then
        echo "fm-child-node-setup: could not create provision.json" >&2
        exit 1
      fi
    }
  if ! fm_child_node_provision_valid "$PROVISION"; then
    echo "fm-child-node-setup: provision.json exists but is not a valid child-node provision; refusing to overwrite" >&2
    exit 1
  fi
fi

CONTAINER_ID=$(fm_child_node_container_id "$CHILD_HOME") || {
  echo "fm-child-node-setup: provision.json is not a complete Child Node provision shape" >&2
  exit 1
}

CHILD_TYPE=$(fm_child_node_type_for_kind "$KIND")
CAPS_JSON=$(fm_child_node_capability_tokens | jq -R . | jq -s -c .)
jq -n \
  --arg child_type "$CHILD_TYPE" \
  --arg version "$CHILD_VERSION" \
  --arg display_name "$TASK_ID" \
  --arg parent_id "$PARENT_ID" \
  --arg home_hint "$FM_HOME" \
  --argjson capabilities "$CAPS_JSON" \
  '{
    schema:"dev.vellum.child/1",
    child_type:$child_type,
    child_version:$version,
    contract_versions:[1],
    display_name:$display_name,
    capabilities:$capabilities,
    parent:{kind:"god-node",container_id:$parent_id,home_hint:$home_hint}
  }' \
  | fm_resident_atomic_json "$CHILD"
