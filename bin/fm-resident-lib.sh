#!/usr/bin/env bash
# Crew Lead resident-container contract helpers.
# Source this file; use fm_resident_atomic_json <destination> to validate JSON,
# fsync a same-directory temporary file, rename it into place, and best-effort
# fsync the containing directory.

fm_resident_atomic_json() {  # <destination>
  local destination=$1 directory temporary
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
  mv -f "$temporary" "$destination"
  if command -v sync >/dev/null 2>&1; then
    sync -f "$directory" 2>/dev/null || true
  fi
}

fm_resident_rfc3339() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

fm_resident_container_id() {  # <home>
  jq -er 'select(.schema == "dev.vellum.god-node/1") | .container_id' "$1/.god-node/contract.json"
}

fm_resident_process_identity() {  # <pid>
  local pid=$1 start boot
  if [ -r "/proc/$pid/stat" ]; then
    start=$(awk '{print $22}' "/proc/$pid/stat") || return 1
    boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || printf unknown-boot)
    printf 'linux-proc-v1:%s:%s' "$boot" "$start"
    return 0
  fi
  start=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]][[:space:]]*/ /g')
  [ -n "$start" ] || return 1
  printf 'ps-lstart-v1:%s' "$start"
}
