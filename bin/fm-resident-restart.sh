#!/usr/bin/env bash
# Re-publish the current Crew Lead session through the session-lock authority.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/fm-lock.sh"
