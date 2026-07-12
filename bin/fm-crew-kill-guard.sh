#!/usr/bin/env bash
# Fail-closed command guard installed by fm-spawn.sh for crew and scout agents.
#
# Usage:
#   fm-crew-kill-guard.sh [--claude] --command '<shell command>'
#   <PreToolUse JSON> | fm-crew-kill-guard.sh [--claude]
set -u

CLAUDE_MODE=0
COMMAND=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude) CLAUDE_MODE=1; shift ;;
    --command) [ "$#" -ge 2 ] || break; COMMAND=$2; shift 2 ;;
    *) break ;;
  esac
done

RULE='Process signaling by pattern or sweep is denied. Only kill/kill -<signal> of individually verified explicit numeric PIDs owned by this task is allowed. The live app, desktop session, and herdr processes are untouchable. Escalate instead of retrying a variant.'

deny() {
  local escaped
  escaped=$(printf '%s' "[crew-kill-guard] $RULE" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$escaped" >&2
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$escaped"
  exit 2
}

if [ -z "$COMMAND" ]; then
  command -v jq >/dev/null 2>&1 || deny
  payload=$(cat 2>/dev/null) || deny
  [ -n "$payload" ] || deny
  COMMAND=$(printf '%s' "$payload" | jq -er '.tool_input.command // .toolInput.command // empty' 2>/dev/null) || deny
  [ -n "$COMMAND" ] || deny
fi

# Collapse continuations and space so command-position checks cover multiline loops.
flat=${COMMAND//$'\\\n'/}
flat=${flat//$'\n'/;}

# These utilities have no safe crew use: every invocation is a pattern/sweep kill.
if [[ $flat =~ (^|[\;\&\|\(][[:space:]]*|[[:space:]](then|do)[[:space:]]+)(command[[:space:]]+|sudo[[:space:]]+([^[:space:]]+[[:space:]]+)*|([^[:space:]]*/)?env[[:space:]]+([^[:space:]=]+=[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*)*([^[:space:]]*/)?(pkill|killall)([[:space:]]|$) ]]; then
  deny
fi
if [[ $flat =~ (^|[[:space:]/])(bash|sh|zsh|dash|ksh)[[:space:]][^\;\&\|]*-[^[:space:]]*c[[:space:]] ]] &&
   [[ $flat =~ (pkill|killall|fuser[[:space:]][^\;\&\|]*--kill|fuser[[:space:]][^\;\&\|]*-[A-Za-z]*k|kill[[:space:]][^\;\&\|]*(\$\(|\`|pgrep|xargs|ps[[:space:]]|grep|rg[[:space:]])) ]]; then
  deny
fi
if [[ $flat =~ (^|[[:space:]/])(eval|exec)[[:space:]] ]] &&
   [[ $flat =~ (pkill|killall|fuser[[:space:]][^\;\&\|]*--kill|fuser[[:space:]][^\;\&\|]*-[A-Za-z]*k|kill[[:space:]][^\;\&\|]*(\$\(|\`|pgrep|xargs|ps[[:space:]]|grep|rg[[:space:]])) ]]; then
  deny
fi
if [[ $flat =~ (^|[\;\&\|\(][[:space:]]*|[[:space:]](then|do)[[:space:]]+)(command[[:space:]]+|sudo[[:space:]]+([^[:space:]]+[[:space:]]+)*|([^[:space:]]*/)?env[[:space:]]+([^[:space:]=]+=[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*)*([^[:space:]]*/)?fuser[[:space:]][^\;\&\|]*(--kill|-[A-Za-z]*k) ]]; then
  deny
fi
if [[ $flat =~ (^|[[:space:]/])(bash|sh|zsh|dash|ksh)[[:space:]][^\;\&\|]*-[^[:space:]]*c[[:space:]][^\;\&\|]*([^[:space:]]*/)?kill([[:space:]]|$) ]] ||
   [[ $flat =~ (^|[[:space:]/])(eval|exec)[[:space:]][^\;\&\|]*([^[:space:]]*/)?kill([[:space:]]|$) ]] ||
   [[ $flat =~ (^|[\;\&\|\(][[:space:]]*|[[:space:]](then|do)[[:space:]]+)(([^[:space:]]*/)?env[[:space:]]+([^[:space:]=]+=[^[:space:]]+[[:space:]]+|-[^[:space:]]+[[:space:]]+)*)+([^[:space:]]*/)?kill([[:space:]]|$) ]]; then
  deny
fi

# xargs can manufacture an arbitrary PID list after the hook has made its decision.
if [[ $flat =~ (^|[\;\&\|\(][[:space:]]*|[[:space:]](then|do)[[:space:]]+)([^[:space:]]*/)?xargs([^\;\&\|]*[[:space:]])([^[:space:]]*/)?kill([[:space:]]|$) ]]; then
  deny
fi

# A kill fed by substitution, a pipeline, pgrep, ps/grep, or a loop is a sweep.
if [[ $flat =~ (pgrep|ps[[:space:]]|grep|rg[[:space:]]|xargs)[^\n\;]*(\||\$\(|\`)[^\n\;]*kill ]] ||
   [[ $flat =~ kill[^\n\;]*(\$\(|\`|pgrep|xargs) ]] ||
   [[ $flat =~ (for|while|until)[[:space:]].*kill ]]; then
  deny
fi

# Every actual kill command must contain only signal options and literal numeric PIDs.
rest=$flat
while [[ $rest =~ (^|[\;\&\|\(][[:space:]]*|[[:space:]](then|do)[[:space:]]+)(command[[:space:]]+|sudo[[:space:]]+([^[:space:]]+[[:space:]]+)*)?([^[:space:]]*/)?kill([[:space:]]+[^\;\&\|\)]*)? ]]; do
  args=${BASH_REMATCH[6]:-}
  args=${args#"${args%%[![:space:]]*}"}
  [ -n "$args" ] || deny
  end_options=0
  signal_seen=0
  pid_seen=0
  for arg in $args; do
    if [ "$end_options" -eq 0 ] && [ "$arg" = -- ]; then
      end_options=1
      continue
    fi
    if [ "$end_options" -eq 0 ] && [ "$signal_seen" -eq 0 ] && [[ $arg =~ ^-[0-9]+$|^-[A-Za-z]+$ ]]; then
      signal_seen=1
      continue
    fi
    if [[ $arg =~ ^[1-9][0-9]*$ ]]; then
      pid_seen=1
      continue
    fi
    deny
  done
  [ "$pid_seen" -eq 1 ] || deny
  rest=${rest#*"${BASH_REMATCH[0]}"}
done

exit 0
