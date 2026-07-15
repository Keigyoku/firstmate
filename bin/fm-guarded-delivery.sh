#!/usr/bin/env bash
set -euo pipefail

guard=$1
shift
if [ -n "$guard" ]; then
  "$guard"
fi
exec "$@"
