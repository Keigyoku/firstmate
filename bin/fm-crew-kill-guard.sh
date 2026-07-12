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

TOKENS=()
tokenize_command() {
  local src=${1//$'\\\n'/}
  local i=0 len=${#src} token='' char='' quote='' next='' two=''
  TOKENS=()
  while [ "$i" -lt "$len" ]; do
    char=${src:i:1}
    case "$char" in
      [[:space:]]) i=$((i + 1)); continue ;;
      '#')
        while [ "$i" -lt "$len" ] && [ "${src:i:1}" != $'\n' ]; do i=$((i + 1)); done
        continue
        ;;
      ';'|'&'|'|'|'('|')'|'{'|'}'|'!')
        two=${src:i:2}
        case "$two" in '&&'|'||'|'|&'|';;') TOKENS+=("$two"); i=$((i + 2));; *) TOKENS+=("$char"); i=$((i + 1));; esac
        continue
        ;;
    esac
    token=
    quote=
    while [ "$i" -lt "$len" ]; do
      char=${src:i:1}
      if [ -z "$quote" ]; then
        case "$char" in
          [[:space:]]|';'|'&'|'|'|'('|')'|'{'|'}'|'!') break ;;
          "'") quote="'"; i=$((i + 1)); continue ;;
          '"') quote='"'; i=$((i + 1)); continue ;;
          "\\")
            if [ $((i + 1)) -lt "$len" ]; then
              next=${src:i+1:1}
              if [ "$next" != $'\n' ]; then token+=$next; fi
              i=$((i + 2))
              continue
            fi
            ;;
        esac
      elif [ "$quote" = "'" ]; then
        if [ "$char" = "'" ]; then quote=; i=$((i + 1)); continue; fi
      else
        if [ "$char" = '"' ]; then quote=; i=$((i + 1)); continue; fi
        if [ "$char" = "\\" ] && [ $((i + 1)) -lt "$len" ]; then
          next=${src:i+1:1}
          token+=$next
          i=$((i + 2))
          continue
        fi
      fi
      token+=$char
      i=$((i + 1))
    done
    [ -z "$quote" ] || return 1
    TOKENS+=("$token")
  done
}

base_name() {
  local value=$1
  value=${value##*/}
  printf '%s\n' "$value"
}

is_command_separator() {
  case "$1" in ';'|'&'|'&&'|'||'|'|'|'|&'|';;'|'('|')'|'{'|'}'|'!') return 0 ;; *) return 1 ;; esac
}

is_reserved_intro() {
  case "$1" in if|then|else|elif|do|done|while|until|for|select|"case"|in|"esac"|fi) return 0 ;; *) return 1 ;; esac
}

skip_sudo_options() {
  local -n _words=$1
  local i=$2 arg opt
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && { printf '%s\n' $((i + 1)); return; }
    [[ $arg == -* && $arg != - ]] || break
    opt=${arg#-}
    opt=${opt%%=*}
    case "$opt" in *[CgHhprRTtUu]*) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac
  done
  printf '%s\n' "$i"
}

skip_env_options() {
  local -n _words=$1
  local i=$2 arg
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && { printf '%s\n' $((i + 1)); return; }
    [[ $arg == *=* && $arg != /* ]] && { i=$((i + 1)); continue; }
    [[ $arg == -* && $arg != - ]] || break
    case "$arg" in -u|-C|-S|--unset|--chdir|--split-string) i=$((i + 2)) ;; *=*) i=$((i + 1)) ;; *) i=$((i + 1)) ;; esac
  done
  printf '%s\n' "$i"
}

skip_wrapper_options() {
  local -n _words=$1
  local i=$2 name=$3 arg
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && { i=$((i + 1)); break; }
    [[ $arg == -* && $arg != - ]] || break
    case "$name:$arg" in timeout:-k|timeout:--kill-after|timeout:-s|timeout:--signal|nice:-n|ionice:-c|ionice:-n|chrt:-f|chrt:-r|chrt:-o|stdbuf:-i|stdbuf:-o|stdbuf:-e) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac
  done
  if [ "$name" = timeout ] && [ "$i" -lt "${#_words[@]}" ]; then i=$((i + 1)); fi
  printf '%s\n' "$i"
}

literal_payload_after_shell_c() {
  local -n _words=$1
  local i=$2 arg
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    if [[ $arg == -*c* ]]; then
      [ $((i + 1)) -lt "${#_words[@]}" ] || return 1
      printf '%s\n' "${_words[$((i + 1))]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

validate_kill_args() {
  local -n _words=$1
  local i=$2 end_options=0 signal_seen=0 pid_seen=0 arg
  [ "$i" -lt "${#_words[@]}" ] || return 1
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    if [ "$end_options" -eq 0 ] && [ "$arg" = -- ]; then
      end_options=1
      i=$((i + 1))
      continue
    fi
    if [ "$end_options" -eq 0 ] && [ "$signal_seen" -eq 0 ] && [[ $arg =~ ^-[0-9]+$|^-[A-Za-z]+$ ]]; then
      signal_seen=1
      i=$((i + 1))
      continue
    fi
    [[ $arg =~ ^[1-9][0-9]*$ ]] || return 1
    pid_seen=1
    i=$((i + 1))
  done
  [ "$pid_seen" -eq 1 ]
}

command_words_are_denied() {
  local words_name=$1
  local -n words=$words_name
  local i=0 name payload direct_prefix=0 wrapped=0
  while [ "$i" -lt "${#words[@]}" ]; do
    [[ ${words[$i]} == *=* && ${words[$i]} != /* ]] || break
    i=$((i + 1))
  done
  while [ "$i" -lt "${#words[@]}" ] && is_reserved_intro "${words[$i]}"; do i=$((i + 1)); done
  [ "$i" -lt "${#words[@]}" ] || return 1
  while [ "$i" -lt "${#words[@]}" ]; do
    name=$(base_name "${words[$i]}")
    case "$name" in
      command|builtin) direct_prefix=1; i=$((i + 1)); continue ;;
      sudo) direct_prefix=1; i=$(skip_sudo_options words $((i + 1))); continue ;;
      env) wrapped=1; i=$(skip_env_options words $((i + 1))); continue ;;
      exec) wrapped=1; i=$((i + 1)); continue ;;
      eval)
        payload=${words[*]:$((i + 1))}
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        return 1
        ;;
      bash|sh|zsh|dash|ksh)
        payload=$(literal_payload_after_shell_c words $((i + 1)) 2>/dev/null || true)
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        return 1
        ;;
      time|gtime|nohup|setsid|timeout|gtimeout|nice|ionice|chrt|stdbuf|unbuffer)
        wrapped=1
        i=$(skip_wrapper_options words $((i + 1)) "$name")
        continue
        ;;
      xargs) return 0 ;;
    esac
    break
  done
  [ "$i" -lt "${#words[@]}" ] || return 1
  name=$(base_name "${words[$i]}")
  case "$name" in
    pkill|killall) return 0 ;;
    fuser)
      local arg
      for arg in "${words[@]:$((i + 1))}"; do
        [[ $arg == --kill || $arg =~ ^-[A-Za-z]*k[A-Za-z]* ]] && return 0
      done
      ;;
    kill)
      [ "$wrapped" -eq 0 ] || return 0
      validate_kill_args words $((i + 1)) || return 0
      ;;
  esac
  [ "$direct_prefix" -eq 1 ] && :
  return 1
}

command_string_is_denied() {
  local src=$1 tok word
  local current=()
  local dollar_paren backtick
  printf -v dollar_paren '%s%s' '$' '('
  printf -v backtick '%s' '`'
  tokenize_command "$src" || return 0
  for tok in "${TOKENS[@]}"; do
    if is_command_separator "$tok"; then
      if [ "${#current[@]}" -gt 0 ]; then
        command_words_are_denied current && return 0
        current=()
      fi
      continue
    fi
    current+=("$tok")
  done
  if [ "${#current[@]}" -gt 0 ]; then
    command_words_are_denied current && return 0
  fi
  for word in "${TOKENS[@]}"; do
    case "$word" in *"$dollar_paren"*|*"$backtick"*) return 0 ;; esac
  done
  return 1
}

command_string_is_denied "$COMMAND" && deny

exit 0
