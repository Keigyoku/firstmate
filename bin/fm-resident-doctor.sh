#!/usr/bin/env bash
# Validate Crew Lead contract metadata and the current pointer when present.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${GOD_NODE_HOME:-${RESIDENT_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}}"

# shellcheck source=bin/fm-resident-lib.sh
. "$SCRIPT_DIR/fm-resident-lib.sh"

jq -e '.schema == "dev.vellum.god-node/1" and .minimum_reader == 1 and has("container_id") == false and has("created_at") == false and has("identity_kind") == false' "$FM_HOME/.god-node/contract.json" >/dev/null
jq -e '.schema == "dev.vellum.god-node.provision/1" and .identity_kind == "resident-container" and (.container_id | type == "string")' "$FM_HOME/.god-node/provision.json" >/dev/null
jq -e '.schema == "dev.vellum.resident/1" and (.contract_versions | index(1)) != null' "$FM_HOME/.god-node/resident.json" >/dev/null

# Descriptor must advertise the full multi-harness transcript set.
REQUIRED_CAPS=$(fm_resident_capability_tokens)
while IFS= read -r cap; do
  [ -n "$cap" ] || continue
  jq -e --arg cap "$cap" '.capabilities | index($cap) != null' "$FM_HOME/.god-node/resident.json" >/dev/null \
    || { echo "fm-resident-doctor: missing capability $cap" >&2; exit 1; }
done <<<"$REQUIRED_CAPS"

if [ -e "$FM_HOME/state/resident-current.json" ]; then
  ID=$(jq -r '.container_id' "$FM_HOME/.god-node/provision.json")
  jq -e --arg id "$ID" '.schema == "dev.vellum.resident-current/1" and .container_id == $id and (.epoch | type == "number")' "$FM_HOME/state/resident-current.json" >/dev/null

  # When conversation is published, assert harness/adapter/id/path for any harness
  # (not only Claude). Adapter must match the ADR 0056 map for that harness.
  if jq -e '.conversation != null' "$FM_HOME/state/resident-current.json" >/dev/null 2>&1; then
    CONV_HARNESS=$(jq -r '.conversation.harness // empty' "$FM_HOME/state/resident-current.json")
    CONV_ADAPTER=$(jq -r '.conversation.transcript.adapter // empty' "$FM_HOME/state/resident-current.json")
    CONV_ID=$(jq -r '.conversation.transcript.id // .conversation.session_id // empty' "$FM_HOME/state/resident-current.json")
    CONV_PATH=$(jq -r '.conversation.transcript.path // empty' "$FM_HOME/state/resident-current.json")
    [ -n "$CONV_HARNESS" ] || { echo "fm-resident-doctor: conversation.harness missing" >&2; exit 1; }
    [ -n "$CONV_ADAPTER" ] || { echo "fm-resident-doctor: conversation.transcript.adapter missing" >&2; exit 1; }
    [ -n "$CONV_ID" ] || { echo "fm-resident-doctor: conversation transcript id missing" >&2; exit 1; }
    [ -n "$CONV_PATH" ] || { echo "fm-resident-doctor: conversation.transcript.path missing" >&2; exit 1; }
    case "$CONV_PATH" in
      /*) ;;
      *) echo "fm-resident-doctor: conversation.transcript.path must be absolute" >&2; exit 1 ;;
    esac
    EXPECTED=$(fm_resident_transcript_adapter "$CONV_HARNESS" 2>/dev/null || true)
    if [ -n "$EXPECTED" ] && [ "$CONV_ADAPTER" != "$EXPECTED" ]; then
      echo "fm-resident-doctor: adapter $CONV_ADAPTER does not match harness $CONV_HARNESS (expected $EXPECTED)" >&2
      exit 1
    fi
    CAP_TOKEN="transcript.$CONV_ADAPTER"
    jq -e --arg cap "$CAP_TOKEN" '.capabilities | index($cap) != null' "$FM_HOME/.god-node/resident.json" >/dev/null \
      || { echo "fm-resident-doctor: descriptor lacks capability $CAP_TOKEN for published conversation" >&2; exit 1; }
  fi
fi
printf 'Crew Lead resident contract: healthy\n'
