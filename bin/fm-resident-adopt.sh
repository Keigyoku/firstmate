#!/usr/bin/env bash
# Adopt an existing firstmate home as a Crew Lead container without moving it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/fm-resident-setup.sh"
"$SCRIPT_DIR/fm-resident-doctor.sh"
