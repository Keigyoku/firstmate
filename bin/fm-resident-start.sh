#!/usr/bin/env bash
# Publish the current Crew Lead session without starting a parallel tracker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/fm-lock.sh"
