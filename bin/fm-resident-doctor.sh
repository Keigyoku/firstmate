#!/usr/bin/env bash
# Validate Crew Lead contract metadata and the current pointer when present.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${GOD_NODE_HOME:-${RESIDENT_HOME:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}}}"
jq -e '.schema == "dev.vellum.god-node/1" and .identity_kind == "resident-container" and .minimum_reader == 1' "$FM_HOME/.god-node/contract.json" >/dev/null
jq -e '.schema == "dev.vellum.resident/1" and (.contract_versions | index(1)) != null' "$FM_HOME/.god-node/resident.json" >/dev/null
if [ -e "$FM_HOME/state/resident-current.json" ]; then
  ID=$(jq -r '.container_id' "$FM_HOME/.god-node/contract.json")
  jq -e --arg id "$ID" '.schema == "dev.vellum.resident-current/1" and .container_id == $id and (.epoch | type == "number")' "$FM_HOME/state/resident-current.json" >/dev/null
fi
printf 'Crew Lead resident contract: healthy\n'
