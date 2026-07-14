#!/usr/bin/env bash
# fm-send cursor mid-turn follow-up queue push (double Enter).
#
# While cursor-agent is mid-turn, the first Enter only queues a follow-up
# (composer clears, so submit looks landed) and a second Enter pushes it for
# immediate delivery. fm-send scopes that extra Enter when meta harness=cursor
# AND the pane shows the busy signature before typing. These tests pin the
# scoping matrix hermetically (stubbed tmux + sleep, no real agent):
#
#   cursor + busy footer  -> two Enter keypresses after the typed text
#   cursor + idle pane    -> one Enter (single submit stays correct)
#   claude + busy footer  -> one Enter (non-cursor harness unchanged)
#   explicit session:win  -> one Enter (no meta -> harness unknown -> no push)
#   herdr native idle + busy footer -> two Enter keypresses
#
# Enter counts come from a send-keys log; busy vs idle is driven by what the
# fake capture-pane returns for the pre-submit fm_pane_is_busy read vs the
# post-Enter composer-empty read (empty bordered composer => submit landed).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-cursor-queue)

# make_stubs <dir>: fake tmux + sleep.
# Busy vs idle is selected per run via FM_TMUX_CAPTURE_MODE.
# capture-pane with -E or -e (composer row read) always returns an empty
# bordered line so submit verifies as landed; capture-pane without those
# flags (busy tail read) returns the busy footer or an idle follow-up line.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    for a in "$@"; do
      if [ "$a" = Enter ]; then
        printf 'Enter\n' >> "$FM_SEND_KEYS_LOG"
      fi
    done
    exit 0
    ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0
    ;;
  capture-pane)
    # Composer-state uses -e and -E <cy>; busy-check uses -S -40 only.
    for a in "$@"; do
      if [ "$a" = -E ] || [ "$a" = -e ]; then
        printf '\xe2\x94\x82 \xe2\x94\x82\n'
        exit 0
      fi
    done
    if [ "${FM_TMUX_CAPTURE_MODE:-idle}" = busy ]; then
      printf '%s\n' '  Running  12 tokens' '  → Add a follow-up' '  ctrl+c to stop'
    else
      printf '%s\n' '  → Add a follow-up' '  Cursor Grok'
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SLEEP'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SLEEP
  chmod +x "$fb/sleep"
  cat > "$fb/herdr" <<'HERDR'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --session ]; then
  shift 2
fi
case "${1:-}" in
  status)
    printf '{"server":{"running":true}}\n'
    exit 0
    ;;
  pane)
    case "${2:-}" in
      send-text) exit 0 ;;
      send-keys)
        if [ "${4:-}" = enter ]; then
          printf 'Enter\n' >> "$FM_SEND_KEYS_LOG"
        fi
        exit 0
        ;;
      read)
        if [ "${FM_HERDR_CAPTURE_MODE:-idle}" = busy ]; then
          printf '%s\n' '  Running  12 tokens' '  → Add a follow-up' '  ctrl+c to stop'
        else
          printf '%s\n' '  → Add a follow-up' '  Cursor Grok'
        fi
        exit 0
        ;;
    esac
    ;;
  agent)
    if [ "${2:-}" = get ]; then
      count=0
      if [ -f "$FM_HERDR_AGENT_GET_COUNT" ]; then
        count=$(cat "$FM_HERDR_AGENT_GET_COUNT")
      fi
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_HERDR_AGENT_GET_COUNT"
      if [ "${FM_HERDR_AGENT_ALWAYS_IDLE:-0}" = 1 ]; then
        printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
      elif [ "$count" -le 2 ]; then
        printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
      else
        printf '{"result":{"agent":{"agent_status":"working"}}}\n'
      fi
      exit 0
    fi
    ;;
esac
exit 0
HERDR
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

# run_case <label> <harness|--explicit> <busy|idle> <expected-enters>
run_case() {
  local label=$1 harness=$2 mode=$3 expected=$4
  local dir fb log keys home target rc count meta_id
  dir="$TMP_ROOT/case-$RANDOM"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/sleep.log"; keys="$dir/keys.log"; home="$dir"
  mkdir -p "$home/state"
  if [ "$harness" = --explicit ]; then
    target="sess:win"
  else
    target="fm-cqcase"
    meta_id=cqcase
    fm_write_meta "$home/state/$meta_id.meta" "window=sess:win" "harness=$harness"
  fi
  : > "$log"
  : > "$keys"
  env FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.01 \
    PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SLEEP_LOG="$log" FM_SEND_KEYS_LOG="$keys" \
    FM_TMUX_CAPTURE_MODE="$mode" \
    "$SEND" "$target" "steer me" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  count=$(grep -c '^Enter$' "$keys" || true)
  [ "$count" = "$expected" ] || fail "$label: expected $expected Enter(s), got $count"$'\n'"--- keys ---"$'\n'"$(cat "$keys")"
  pass "fm-send cursor-queue: $label -> ${expected} Enter(s)"
}

# run_herdr_case <label> <busy|idle> <expected-enters>
run_herdr_case() {
  local label=$1 mode=$2 expected=$3
  local dir fb log keys home rc count get_count
  dir="$TMP_ROOT/case-$RANDOM"; mkdir -p "$dir"
  fb=$(make_stubs "$dir")
  log="$dir/sleep.log"; keys="$dir/keys.log"; home="$dir"; get_count="$dir/agent-get-count"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/cqherdr.meta" "window=default:w1:p2" "backend=herdr" "harness=cursor"
  : > "$log"
  : > "$keys"
  : > "$get_count"
  env FM_SEND_SETTLE=0 FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.01 \
    FM_BACKEND_HERDR_SUBMIT_POLLS=1 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.01 \
    PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SLEEP_LOG="$log" FM_SEND_KEYS_LOG="$keys" \
    FM_HERDR_CAPTURE_MODE="$mode" FM_HERDR_AGENT_GET_COUNT="$get_count" \
    FM_HERDR_AGENT_ALWAYS_IDLE="$([ "$mode" = busy ] && printf 1 || printf 0)" \
    "$SEND" "fm-cqherdr" "steer me" 2>/dev/null; rc=$?
  expect_code 0 "$rc" "$label: send should succeed"
  count=$(grep -c '^Enter$' "$keys" || true)
  [ "$count" = "$expected" ] || fail "$label: expected $expected Enter(s), got $count"$'\n'"--- keys ---"$'\n'"$(cat "$keys")"
  pass "fm-send cursor-queue: $label -> ${expected} Enter(s)"
}

run_case 'cursor busy -> double Enter' cursor busy 2
run_case 'cursor idle -> single Enter' cursor idle 1
run_case 'claude busy -> single Enter' claude busy 1
run_case 'explicit target busy -> single Enter' --explicit busy 1
run_herdr_case 'herdr native idle + busy footer -> double Enter' busy 2
run_herdr_case 'herdr native idle + idle pane -> single Enter' idle 1
