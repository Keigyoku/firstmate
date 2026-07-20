#!/usr/bin/env bash
# Canonical desktop "glass" capture for captain-facing app-state claims.
#
# Proven capture on the captain's KDE Plasma / Wayland host (2026-07-20):
#   XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
#     spectacle -b -n -f -o <out.png>
#
# Usage:
#   bin/fm-glass.sh [output-path]
#
# Writes a PNG (caller path or a default under fm-state/glass/), prints the
# absolute path on stdout, and records a freshness marker at
#   $FM_HOME/fm-state/last-glass-capture
# containing "epoch path" for bin/fm-claim-guard.sh.
#
# Degrades with a clear stderr error (exit 1) when spectacle or the Wayland
# session socket is unavailable (SSH, headless, secondmate homes without a
# desktop). Never blocks a turn by itself; only the claim guard does.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_ROOT=${FM_ROOT_OVERRIDE:-${CLAUDE_PROJECT_DIR:-$SCRIPT_ROOT}}
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

usage() {
  cat <<'EOF'
Usage: fm-glass.sh [output-path]

Capture the live desktop glass with spectacle and record a freshness marker
under fm-state/last-glass-capture for the primary claim guard.

Prints the absolute capture path on success.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

# Prefer the ambient session; fall back to the host's documented daily-driver
# Wayland socket so a plain firstmate shell still captures.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
: "${WAYLAND_DISPLAY:=wayland-0}"
export XDG_RUNTIME_DIR WAYLAND_DISPLAY

if ! command -v spectacle >/dev/null 2>&1; then
  printf '%s\n' 'fm-glass: spectacle not found on PATH - cannot capture the desktop glass' >&2
  exit 1
fi

WAYLAND_SOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
if [ ! -S "$WAYLAND_SOCK" ]; then
  printf '%s\n' "fm-glass: Wayland socket missing at $WAYLAND_SOCK (SSH/headless/no desktop session) - cannot capture the glass" >&2
  exit 1
fi

OUT=${1:-}
if [ -z "$OUT" ]; then
  mkdir -p "$FM_HOME/fm-state/glass" || {
    printf '%s\n' "fm-glass: cannot create $FM_HOME/fm-state/glass" >&2
    exit 1
  }
  OUT="$FM_HOME/fm-state/glass/capture-$(date +%s).png"
fi

OUT_DIR=$(dirname -- "$OUT")
mkdir -p "$OUT_DIR" || {
  printf '%s\n' "fm-glass: cannot create output directory $OUT_DIR" >&2
  exit 1
}

# -b background (no GUI), -n no notification, -f full desktop, -o output path
if ! spectacle -b -n -f -o "$OUT" 2>/tmp/fm-glass-spectacle.err; then
  err=$(cat /tmp/fm-glass-spectacle.err 2>/dev/null || true)
  printf '%s\n' "fm-glass: spectacle capture failed${err:+: $err}" >&2
  exit 1
fi

if [ ! -s "$OUT" ]; then
  printf '%s\n' "fm-glass: spectacle reported success but output is missing or empty: $OUT" >&2
  exit 1
fi

# Resolve absolute path for the marker and stdout contract.
case "$OUT" in
  /*) ABS_OUT=$OUT ;;
  *) ABS_OUT=$(cd "$(dirname -- "$OUT")" && pwd)/$(basename -- "$OUT") ;;
esac

MARKER_DIR="$FM_HOME/fm-state"
MARKER="$MARKER_DIR/last-glass-capture"
mkdir -p "$MARKER_DIR" || {
  printf '%s\n' "fm-glass: cannot create marker dir $MARKER_DIR" >&2
  exit 1
}
EPOCH=$(date +%s)
TMP="$MARKER.tmp.$$"
if ! printf '%s %s\n' "$EPOCH" "$ABS_OUT" > "$TMP"; then
  rm -f "$TMP"
  printf '%s\n' "fm-glass: cannot write marker $MARKER" >&2
  exit 1
fi
mv -f "$TMP" "$MARKER"

printf '%s\n' "$ABS_OUT"
exit 0
