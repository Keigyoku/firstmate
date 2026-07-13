#!/usr/bin/env bash
# Provision the Crew Lead producer metadata in an existing firstmate home.
# Usage: fm-resident-setup.sh
# Idempotent: contract.json and its container UUID are never replaced.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${GOD_NODE_HOME:-${RESIDENT_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}}"
CONTRACT_DIR="$FM_HOME/.god-node"
CONTRACT="$CONTRACT_DIR/contract.json"
RESIDENT="$CONTRACT_DIR/resident.json"

# shellcheck source=bin/fm-resident-lib.sh
. "$SCRIPT_DIR/fm-resident-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "fm-resident-setup: jq is required" >&2; exit 1; }
mkdir -p "$CONTRACT_DIR" "$FM_HOME/state" "$FM_HOME/inbox/requests" "$FM_HOME/inbox/results"

if [ ! -e "$CONTRACT" ]; then
  if command -v uuidgen >/dev/null 2>&1; then
    CONTAINER_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    CONTAINER_ID=$(cat /proc/sys/kernel/random/uuid)
  else
    echo "fm-resident-setup: uuidgen or /proc/sys/kernel/random/uuid is required" >&2
    exit 1
  fi
  CREATED_AT=$(fm_resident_rfc3339)
  jq -n \
    --arg container_id "$CONTAINER_ID" \
    --arg created_at "$CREATED_AT" \
    '{schema:"dev.vellum.god-node/1",container_id:$container_id,created_at:$created_at,identity_kind:"resident-container",minimum_reader:1}' \
    | fm_resident_atomic_json "$CONTRACT"
fi

CONTAINER_ID=$(fm_resident_container_id "$FM_HOME")
case "$CONTAINER_ID" in
  ????????-????-4???-[89ab]???-????????????) ;;
  *) echo "fm-resident-setup: contract.json has an invalid UUID-v4 container_id" >&2; exit 1 ;;
esac

REVISION=$(git -C "$FM_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)
jq -n \
  --arg version "git:$REVISION" \
  '{schema:"dev.vellum.resident/1",resident_type:"firstmate",resident_version:$version,contract_versions:[1],entrypoints:{setup:["bin/fm-resident-setup.sh"],adopt:["bin/fm-resident-adopt.sh"],start:["bin/fm-resident-start.sh"],restart:["bin/fm-resident-restart.sh"],doctor:["bin/fm-resident-doctor.sh"]},capabilities:["input.file-v1","input.backend-v1","transcript.claude-jsonl-v1","transcript.codex-jsonl-v1"]}' \
  | fm_resident_atomic_json "$RESIDENT"
