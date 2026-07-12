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
TOKEN_SUBS=()
tokenize_command() {
  local src=${1//$'\\\n'/}
  local i=0 len=${#src} token='' token_subs=0 char='' quote='' next='' two='' hex='' oct=''
  TOKENS=()
  TOKEN_SUBS=()
  while [ "$i" -lt "$len" ]; do
    char=${src:i:1}
    case "$char" in
      $'\n') TOKENS+=("$char"); TOKEN_SUBS+=(0); i=$((i + 1)); continue ;;
      [[:space:]]) i=$((i + 1)); continue ;;
      '#')
        while [ "$i" -lt "$len" ] && [ "${src:i:1}" != $'\n' ]; do i=$((i + 1)); done
        continue
        ;;
      '<')
        case "${src:i:3}" in '<<<'|'<<-') TOKENS+=("${src:i:3}"); TOKEN_SUBS+=(0); i=$((i + 3)); continue ;; esac
        two=${src:i:2}
        case "$two" in '<<'|'<&'|'<>') TOKENS+=("$two"); TOKEN_SUBS+=(0); i=$((i + 2));; *) TOKENS+=("$char"); TOKEN_SUBS+=(0); i=$((i + 1));; esac
        continue
        ;;
      '>')
        two=${src:i:2}
        case "$two" in '>>'|'>&'|'>|') TOKENS+=("$two"); TOKEN_SUBS+=(0); i=$((i + 2));; *) TOKENS+=("$char"); TOKEN_SUBS+=(0); i=$((i + 1));; esac
        continue
        ;;
      '&')
        case "${src:i:3}" in '&>>') TOKENS+=("${src:i:3}"); TOKEN_SUBS+=(0); i=$((i + 3)); continue ;; esac
        two=${src:i:2}
        case "$two" in '&&') TOKENS+=("$two"); TOKEN_SUBS+=(0); i=$((i + 2)); continue ;; '&>') TOKENS+=("$two"); TOKEN_SUBS+=(0); i=$((i + 2)); continue ;; esac
        TOKENS+=("$char"); TOKEN_SUBS+=(0); i=$((i + 1)); continue
        ;;
      '{')
        if [ $((i + 1)) -lt "$len" ] && [[ ${src:i+1:1} != [[:space:]\;\&\|\(\)\<\>] ]]; then
          :
        else
          TOKENS+=("$char"); TOKEN_SUBS+=(0); i=$((i + 1)); continue
        fi
        ;;
      '}')
        if [ $((i + 1)) -lt "$len" ] && [[ ${src:i+1:1} != [[:space:]\;\&\|\(\)\<\>] ]]; then
          :
        else
          TOKENS+=("$char"); TOKEN_SUBS+=(0); i=$((i + 1)); continue
        fi
        ;;
      ';'|'|'|'('|')'|'!')
        two=${src:i:2}
        case "$two" in '||'|'|&'|';;') TOKENS+=("$two"); TOKEN_SUBS+=(0); i=$((i + 2));; *) TOKENS+=("$char"); TOKEN_SUBS+=(0); i=$((i + 1));; esac
        continue
        ;;
    esac
    token=
    token_subs=0
    quote=
    while [ "$i" -lt "$len" ]; do
      char=${src:i:1}
      if [ -z "$quote" ]; then
        case "$char" in
          [[:space:]]|';'|'&'|'|'|'('|')'|'!'|'<'|'>') break ;;
          $'\n') break ;;
          "'") quote="'"; i=$((i + 1)); continue ;;
          '"') quote='"'; i=$((i + 1)); continue ;;
          '$')
            if [ $((i + 1)) -lt "$len" ]; then
              next=${src:i+1:1}
              case "$next" in
                "'") quote=ansi; i=$((i + 2)); continue ;;
                '"') quote='"'; i=$((i + 2)); continue ;;
                '(') token_subs=1 ;;
              esac
            fi
            ;;
          '`') token_subs=1 ;;
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
      elif [ "$quote" = ansi ]; then
        if [ "$char" = "'" ]; then quote=; i=$((i + 1)); continue; fi
        if [ "$char" = "\\" ] && [ $((i + 1)) -lt "$len" ]; then
          next=${src:i+1:1}
          case "$next" in
            n) token+=$'\n'; i=$((i + 2)); continue ;;
            r) token+=$'\r'; i=$((i + 2)); continue ;;
            t) token+=$'\t'; i=$((i + 2)); continue ;;
            a) token+=$'\a'; i=$((i + 2)); continue ;;
            b) token+=$'\b'; i=$((i + 2)); continue ;;
            e|E) token+=$'\e'; i=$((i + 2)); continue ;;
            f) token+=$'\f'; i=$((i + 2)); continue ;;
            v) token+=$'\v'; i=$((i + 2)); continue ;;
            "\\"|"'"|'"'|\?) token+=$next; i=$((i + 2)); continue ;;
            x)
              hex=${src:i+2:2}
              [[ $hex =~ ^[0-9A-Fa-f]{1,2}$ ]] || return 1
              printf -v next '%b' "\\x$hex"
              token+=$next
              i=$((i + 2 + ${#hex}))
              continue
              ;;
            [0-7])
              oct=${src:i+1:3}
              oct=${oct%%[!0-7]*}
              printf -v next '%b' "\\$oct"
              token+=$next
              i=$((i + 1 + ${#oct}))
              continue
              ;;
          esac
          return 1
        fi
      else
        if [ "$char" = '"' ]; then quote=; i=$((i + 1)); continue; fi
        if [ "$char" = "\\" ] && [ $((i + 1)) -lt "$len" ]; then
          next=${src:i+1:1}
          token+=$next
          i=$((i + 2))
          continue
        fi
        case "$char" in '$') [ $((i + 1)) -lt "$len" ] && [ "${src:i+1:1}" = '(' ] && token_subs=1 ;; '`') token_subs=1 ;; esac
      fi
      token+=$char
      i=$((i + 1))
    done
    [ -z "$quote" ] || return 1
    TOKENS+=("$token")
    TOKEN_SUBS+=("$token_subs")
  done
}

base_name() {
  local value=$1
  value=${value##*/}
  printf '%s\n' "$value"
}

is_command_separator() {
  case "$1" in $'\n'|';'|'&'|'&&'|'||'|'|'|'|&'|';;'|'('|')'|'{'|'}'|'!') return 0 ;; *) return 1 ;; esac
}

is_reserved_intro() {
  case "$1" in if|then|else|elif|do|done|while|until|for|select|"case"|in|"esac"|fi|coproc) return 0 ;; *) return 1 ;; esac
}

word_is_dynamic() {
  case "$1" in *'$'*|*'`'*) return 0 ;; *) return 1 ;; esac
}

word_has_brace_expansion() {
  case "$1" in *'{'*','*'}'*|*'{'*'..'*'}'*) return 0 ;; *) return 1 ;; esac
}

find_command_substitution_end() {
  local src=$1 start=$2
  local i=$start len=${#src} depth=1 char='' next='' quote=''
  while [ "$i" -lt "$len" ]; do
    char=${src:i:1}
    if [ -z "$quote" ]; then
      case "$char" in
        "'") quote="'"; i=$((i + 1)); continue ;;
        '"') quote='"'; i=$((i + 1)); continue ;;
        '`')
          i=$(find_backtick_substitution_end "$src" $((i + 1))) || return 1
          i=$((i + 1))
          continue
          ;;
        '$')
          if [ $((i + 1)) -lt "$len" ] && [ "${src:i+1:1}" = '(' ]; then
            depth=$((depth + 1))
            i=$((i + 2))
            continue
          fi
          ;;
        ')')
          depth=$((depth - 1))
          [ "$depth" -eq 0 ] && { printf '%s\n' "$i"; return 0; }
          ;;
        "\\")
          i=$((i + 2))
          continue
          ;;
      esac
    elif [ "$quote" = "'" ]; then
      if [ "$char" = "'" ]; then quote=; fi
    else
      case "$char" in
        '"') quote= ;;
        "\\") i=$((i + 2)); continue ;;
      esac
    fi
    i=$((i + 1))
  done
  return 1
}

find_backtick_substitution_end() {
  local src=$1 i=$2
  local len=${#src} char=''
  while [ "$i" -lt "$len" ]; do
    char=${src:i:1}
    case "$char" in
      '`') printf '%s\n' "$i"; return 0 ;;
      "\\") i=$((i + 2)); continue ;;
    esac
    i=$((i + 1))
  done
  return 1
}

word_substitutions_are_denied() {
  local word=$1 check=${2:-1}
  local i=0 len=${#word} char='' next='' end='' payload=''
  [ "$check" -eq 1 ] || return 1
  while [ "$i" -lt "$len" ]; do
    char=${word:i:1}
    case "$char" in
      '$')
        if [ $((i + 1)) -lt "$len" ]; then
          next=${word:i+1:1}
          if [ "$next" = '(' ]; then
            [ $((i + 2)) -lt "$len" ] && [ "${word:i+2:1}" = '(' ] && { i=$((i + 2)); continue; }
            end=$(find_command_substitution_end "$word" $((i + 2))) || return 0
            payload=${word:i+2:end-i-2}
            [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
            i=$((end + 1))
            continue
          fi
        fi
        ;;
      '`')
        end=$(find_backtick_substitution_end "$word" $((i + 1))) || return 0
        payload=${word:i+1:end-i-1}
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        i=$((end + 1))
        continue
        ;;
      "\\")
        i=$((i + 2))
        continue
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

words_substitutions_are_denied() {
  local -n _words=$1
  local _subs_name=${2:-} i=0 check=1
  if [ -n "$_subs_name" ]; then
    local -n _subs=$_subs_name
  fi
  while [ "$i" -lt "${#_words[@]}" ]; do
    check=1
    [ -z "$_subs_name" ] || check=${_subs[$i]:-0}
    word_substitutions_are_denied "${_words[$i]}" "$check" && return 0
    i=$((i + 1))
  done
  return 1
}

shell_here_string_payloads_are_denied() {
  local -n _words=$1
  local -n _subs=$2
  local i=$3 arg payload payload_subs
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    case "$arg" in
      '<<<'|[0-9]'<<<')
        [ $((i + 1)) -lt "${#_words[@]}" ] || return 0
        payload=${_words[$((i + 1))]}
        payload_subs=${_subs[$((i + 1))]:-0}
        word_substitutions_are_denied "$payload" "$payload_subs" && return 0
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        i=$((i + 2))
        continue
        ;;
    esac
    i=$((i + 1))
  done
  return 1
}

words_have_opaque_stdin_redirection() {
  local -n _words=$1
  local i=$2 arg
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    case "$arg" in
      '<<'|'<<-'|'<<<'|[0-9]'<<'|[0-9]'<<-'|[0-9]'<<<') ;;
      '<'|'<&'|'<>'|'<-'|[0-9]'<'|[0-9]'<&'|[0-9]'<>'|[0-9]'<-'|'<'*|[0-9]'<'*) return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

redirection_needs_operand() {
  case "$1" in
    '<'|'>'|'>>'|'<&'|'>&'|'<>'|'>|'|'&>'|'&>>'|'<<'|'<<-'|'<<<'|[0-9]'<'|[0-9]'>'|[0-9]'>>'|[0-9]'<&'|[0-9]'>&'|[0-9]'<>'|[0-9]'>|'|[0-9]'<<'|[0-9]'<<-'|[0-9]'<<<') return 0 ;;
  esac
  [[ $1 =~ ^[0-9]+(<|>|>>|<\&|>\&|<>|>\||<<|<<-|<<<)$ ]]
}

redirection_has_attached_operand() {
  case "$1" in
    '<'*|'>'*|'&>'*|[0-9]'<'*|[0-9]'>'*)
      redirection_needs_operand "$1" && return 1
      return 0
      ;;
  esac
  [[ $1 =~ ^[0-9]+(<|>|>>|<\&|>\&|<>|>\||<<|<<-|<<<).+ ]]
}

numeric_fd_prefix_word() {
  [[ $1 =~ ^[0-9]+$ ]]
}

normalize_simple_command_words() {
  local -n _in_words=$1
  local -n _in_subs=$2
  local -n _out_words=$3
  local -n _out_subs=$4
  local i=0 word
  _out_words=()
  _out_subs=()
  while [ "$i" -lt "${#_in_words[@]}" ]; do
    word=${_in_words[$i]}
    if numeric_fd_prefix_word "$word" && [ $((i + 1)) -lt "${#_in_words[@]}" ]; then
      if redirection_needs_operand "${_in_words[$((i + 1))]}"; then
        i=$((i + 3))
        continue
      fi
      if redirection_has_attached_operand "${_in_words[$((i + 1))]}"; then
        i=$((i + 2))
        continue
      fi
    fi
    if redirection_needs_operand "$word"; then
      i=$((i + 2))
      continue
    fi
    if redirection_has_attached_operand "$word"; then
      i=$((i + 1))
      continue
    fi
    _out_words+=("$word")
    _out_subs+=("${_in_subs[$i]:-0}")
    i=$((i + 1))
  done
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
    case "$arg" in --*=*) i=$((i + 1)); continue ;; esac
    if [[ $arg =~ ^-[CgHhprRTtUu].+ ]]; then
      i=$((i + 1))
      continue
    fi
    case "$opt" in *[CgHhprRTtUu]*) i=$((i + 2)) ;; *) i=$((i + 1)) ;; esac
  done
  printf '%s\n' "$i"
}

skip_env_options() {
  local -n _words=$1
  local i=$2 arg cluster after_s
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && { printf '%s\n' $((i + 1)); return; }
    if [[ $arg == -* && $arg != - ]]; then
      case "$arg" in
        -u|-C|-S|--unset|--chdir|--split-string) i=$((i + 2)) ;;
        --split-string=*|*=*) i=$((i + 1)) ;;
        --*) i=$((i + 1)) ;;
        -*S*)
          cluster=${arg#-}
          after_s=${cluster#*S}
          if [ -n "$after_s" ]; then i=$((i + 1)); else i=$((i + 2)); fi
          ;;
        *) i=$((i + 1)) ;;
      esac
      continue
    fi
    [[ $arg == *=* && $arg != /* ]] && { i=$((i + 1)); continue; }
    break
  done
  printf '%s\n' "$i"
}

env_split_payloads_are_denied() {
  local -n _words=$1
  local i=$2 arg payload cluster after_s
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && return 1
    if [[ $arg != -* || $arg == - ]]; then
      [[ $arg == *=* && $arg != /* ]] && { i=$((i + 1)); continue; }
      break
    fi
    case "$arg" in
      -S|--split-string)
        [ $((i + 1)) -lt "${#_words[@]}" ] || return 0
        payload=${_words[$((i + 1))]}
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        i=$((i + 2))
        ;;
      --split-string=*)
        payload=${arg#--split-string=}
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        i=$((i + 1))
        ;;
      -*S*)
        cluster=${arg#-}
        after_s=${cluster#*S}
        if [ -n "$after_s" ]; then
          payload=$after_s
          [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
          return 0
        fi
        [ $((i + 1)) -lt "${#_words[@]}" ] || return 0
        payload=${_words[$((i + 1))]}
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        i=$((i + 2))
        ;;
      -u|-C|--unset|--chdir) i=$((i + 2)) ;;
      *=*) i=$((i + 1)) ;;
      *) i=$((i + 1)) ;;
    esac
  done
  return 1
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

skip_command_options() {
  local -n _words=$1
  local i=$2 arg
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && { printf '%s\n' $((i + 1)); return; }
    case "$arg" in
      -p) i=$((i + 1)); continue ;;
      -v|-V) printf '%s\n' "${#_words[@]}"; return ;;
      -*) printf '%s\n' "${#_words[@]}"; return ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$i"
}

skip_builtin_options() {
  local -n _words=$1
  local i=$2
  if [ "$i" -lt "${#_words[@]}" ] && [ "${_words[$i]}" = -- ]; then
    i=$((i + 1))
  fi
  printf '%s\n' "$i"
}

skip_exec_options() {
  local -n _words=$1
  local i=$2 arg
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && { printf '%s\n' $((i + 1)); return; }
    case "$arg" in
      -a) i=$((i + 2)); continue ;;
      -a?*) i=$((i + 1)); continue ;;
      -c|-l) i=$((i + 1)); continue ;;
      -*) printf '%s\n' "${#_words[@]}"; return ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$i"
}

literal_payload_after_shell_c() {
  local -n _words=$1
  local i=$2 arg cluster pos ch after_c
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    case "$arg" in
      --) return 1 ;;
      --rcfile|--init-file|--wordexp|--dump-po-strings) i=$((i + 2)); continue ;;
      --*) i=$((i + 1)); continue ;;
      -?*)
        cluster=${arg#-}
        pos=0
        while [ "$pos" -lt "${#cluster}" ]; do
          ch=${cluster:pos:1}
          case "$ch" in
            c)
              after_c=${cluster:$((pos + 1))}
              if [ -n "$after_c" ]; then
                printf '%s\n' "$after_c"
                return 0
              fi
              [ $((i + 1)) -lt "${#_words[@]}" ] || return 1
              printf '%s\n' "${_words[$((i + 1))]}"
              return 0
              ;;
            O|o)
              if [ $((pos + 1)) -lt "${#cluster}" ]; then
                i=$((i + 1))
              else
                i=$((i + 2))
              fi
              continue 2
              ;;
            *) pos=$((pos + 1)) ;;
          esac
        done
        i=$((i + 1))
        continue
        ;;
      +?*)
        cluster=${arg#+}
        pos=0
        while [ "$pos" -lt "${#cluster}" ]; do
          ch=${cluster:pos:1}
          case "$ch" in
            O|o)
              if [ $((pos + 1)) -lt "${#cluster}" ]; then
                i=$((i + 1))
              else
                i=$((i + 2))
              fi
              continue 2
              ;;
            *) pos=$((pos + 1)) ;;
          esac
        done
        i=$((i + 1))
        continue
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}

xargs_payload_is_denied() {
  local -n _words=$1
  local -n _subs=$2
  local i=$3 arg
  local xargs_cmd_words=()
  local xargs_cmd_subs=()
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    [ "$arg" = -- ] && { i=$((i + 1)); break; }
    [[ $arg == -* && $arg != - ]] || break
    case "$arg" in
      -0|-r|-t|-p|-x|--null|--no-run-if-empty|--verbose|--interactive|--exit|--help|--version)
        i=$((i + 1))
        ;;
      -a|-d|-I|-E|-J|-n|-L|-P|-R|-s|--arg-file|--delimiter|--replace|--eof|--max-args|--max-lines|--max-procs|--max-chars)
        i=$((i + 2))
        ;;
      -a?*|-d?*|-I?*|-E?*|-J?*|-n?*|-L?*|-P?*|-R?*|-s?*|--arg-file=*|--delimiter=*|--replace=*|--eof=*|--max-args=*|--max-lines=*|--max-procs=*|--max-chars=*)
        i=$((i + 1))
        ;;
      *)
        return 0 ;;
    esac
  done
  [ "$i" -lt "${#_words[@]}" ] || return 1
  # shellcheck disable=SC2034
  xargs_cmd_words=("${_words[@]:$i}")
  # shellcheck disable=SC2034
  xargs_cmd_subs=("${_subs[@]:$i}")
  command_words_are_denied xargs_cmd_words xargs_cmd_subs
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

set_alias_payload() {
  local -n _names=$1
  local -n _payloads=$2
  local name=$3 payload=$4 i=0
  while [ "$i" -lt "${#_names[@]}" ]; do
    if [ "${_names[$i]}" = "$name" ]; then
      _payloads[i]=$payload
      return
    fi
    i=$((i + 1))
  done
  _names+=("$name")
  _payloads+=("$payload")
}

alias_payload_for() {
  # shellcheck disable=SC2178
  local -n _names=$1
  # shellcheck disable=SC2178
  local -n _payloads=$2
  local name=$3 i=0
  while [ "$i" -lt "${#_names[@]}" ]; do
    if [ "${_names[$i]}" = "$name" ]; then
      printf '%s\n' "${_payloads[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

update_shopt_alias_state() {
  local -n _words=$1
  local -n _alias_expand=$2
  local i=$3 mode='' arg
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    case "$arg" in
      -s|-u) mode=$arg ;;
      expand_aliases)
        case "$mode" in
          -s) _alias_expand=1 ;;
          -u) _alias_expand=0 ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
}

record_alias_definitions() {
  local -n _words=$1
  local -n _alias_names=$2
  local -n _alias_payloads=$3
  local i=$4 arg name payload
  while [ "$i" -lt "${#_words[@]}" ]; do
    arg=${_words[$i]}
    case "$arg" in
      --|-p) i=$((i + 1)); continue ;;
      *=*)
        name=${arg%%=*}
        payload=${arg#*=}
        case "$name" in
          ''|*[!A-Za-z0-9_]*|[0-9]*) ;;
          *) set_alias_payload _alias_names _alias_payloads "$name" "$payload" ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
}

simple_command_feeds_shell_interpreter() {
  local words_name=$1 subs_name=$2 i=0 name
  local -n _words=$words_name
  local -n _subs=$subs_name
  local normalized_words=()
  local normalized_subs=()
  normalize_simple_command_words _words _subs normalized_words normalized_subs
  _words=("${normalized_words[@]}")
  _subs=("${normalized_subs[@]}")
  while [ "$i" -lt "${#_words[@]}" ]; do
    [[ ${_words[$i]} == *=* && ${_words[$i]} != /* ]] || break
    i=$((i + 1))
  done
  while [ "$i" -lt "${#_words[@]}" ] && is_reserved_intro "${_words[$i]}"; do i=$((i + 1)); done
  while [ "$i" -lt "${#_words[@]}" ]; do
    name=$(base_name "${_words[$i]}")
    case "$name" in
      command) i=$(skip_command_options _words $((i + 1))); continue ;;
      builtin) i=$(skip_builtin_options _words $((i + 1))); continue ;;
      exec) i=$(skip_exec_options _words $((i + 1))); continue ;;
      sudo) i=$(skip_sudo_options _words $((i + 1))); continue ;;
      env) i=$(skip_env_options _words $((i + 1))); continue ;;
      busybox|toybox)
        i=$((i + 1))
        [ "$i" -lt "${#_words[@]}" ] && [ "${_words[$i]}" = -- ] && i=$((i + 1))
        continue
        ;;
      time|gtime|nohup|setsid|timeout|gtimeout|nice|ionice|chrt|stdbuf|unbuffer)
        i=$(skip_wrapper_options _words $((i + 1)) "$name")
        continue
        ;;
    esac
    case "$name" in bash|sh|zsh|dash|ksh) return 0 ;; *) return 1 ;; esac
  done
  return 1
}

line_heredoc_feeds_shell_interpreter() {
  local line=$1 idx=0 tok heredoc_idx=-1 delimiter_idx=-1 scan=0
  local words=()
  local subs=()
  tokenize_command "$line" || return 0
  while [ "$idx" -lt "${#TOKENS[@]}" ]; do
    tok=${TOKENS[$idx]}
    if [ "$tok" = '<<' ] || [ "$tok" = '<<-' ]; then
      heredoc_idx=$idx
      delimiter_idx=$((idx + 1))
      words+=("$tok")
      subs+=("${TOKEN_SUBS[$idx]:-0}")
      if [ "$delimiter_idx" -lt "${#TOKENS[@]}" ]; then
        words+=("${TOKENS[$delimiter_idx]}")
        subs+=("${TOKEN_SUBS[$delimiter_idx]:-0}")
      fi
      break
    fi
    if is_command_separator "$tok"; then
      words=()
      subs=()
      idx=$((idx + 1))
      continue
    fi
    words+=("$tok")
    subs+=("${TOKEN_SUBS[$idx]:-0}")
    idx=$((idx + 1))
  done
  [ "$heredoc_idx" -ge 0 ] || return 1
  scan=$((delimiter_idx + 1))
  while [ "$scan" -lt "${#TOKENS[@]}" ]; do
    tok=${TOKENS[$scan]}
    is_command_separator "$tok" && break
    words+=("$tok")
    subs+=("${TOKEN_SUBS[$scan]:-0}")
    scan=$((scan + 1))
  done
  simple_command_feeds_shell_interpreter words subs
}

redact_non_shell_heredocs() {
  local src=$1 out='' line='' delimiter='' comparable='' strip_tabs=0 keep_body=0
  local idx=0 tok='' delimiter_idx=-1
  while IFS= read -r line || [ -n "$line" ]; do
    out+="$line"$'\n'
    tokenize_command "$line" || continue
    delimiter_idx=-1
    strip_tabs=0
    idx=0
    while [ "$idx" -lt "${#TOKENS[@]}" ]; do
      tok=${TOKENS[$idx]}
      if [ "$tok" = '<<' ] || [ "$tok" = '<<-' ]; then
        delimiter_idx=$((idx + 1))
        [ "$tok" = '<<-' ] && strip_tabs=1
        break
      fi
      idx=$((idx + 1))
    done
    [ "$delimiter_idx" -ge 0 ] || continue
    [ "$delimiter_idx" -lt "${#TOKENS[@]}" ] || continue
    delimiter=${TOKENS[$delimiter_idx]}
    [ -n "$delimiter" ] || continue
    keep_body=1
    line_heredoc_feeds_shell_interpreter "$line" || keep_body=0
    while IFS= read -r line || [ -n "$line" ]; do
      comparable=$line
      if [ "$strip_tabs" -ne 0 ]; then
        while [[ $comparable == $'\t'* ]]; do comparable=${comparable#$'\t'}; done
      fi
      if [ "$comparable" = "$delimiter" ]; then
        [ "$keep_body" -eq 0 ] || out+="$line"$'\n'
        break
      fi
      [ "$keep_body" -eq 0 ] || out+="$line"$'\n'
    done
  done <<< "$src"
  printf '%s' "$out"
}

command_words_are_denied() {
  local words_name=$1
  local subs_name=$2
  local alias_expand_name=${3:-}
  local alias_names_name=${4:-}
  local alias_payloads_name=${5:-}
  local -n _cmd_words=$words_name
  local -n _cmd_subs=$subs_name
  local i=0 name payload direct_prefix=0 wrapped=0
  local original_words=("${_cmd_words[@]}")
  local original_subs=("${_cmd_subs[@]}")
  local normalized_words=()
  local normalized_subs=()
  : "${original_words[@]}" "${original_subs[@]}"
  words_substitutions_are_denied _cmd_words _cmd_subs && return 0
  normalize_simple_command_words _cmd_words _cmd_subs normalized_words normalized_subs
  _cmd_words=("${normalized_words[@]}")
  _cmd_subs=("${normalized_subs[@]}")
  while [ "$i" -lt "${#_cmd_words[@]}" ]; do
    [[ ${_cmd_words[$i]} == *=* && ${_cmd_words[$i]} != /* ]] || break
    i=$((i + 1))
  done
  while [ "$i" -lt "${#_cmd_words[@]}" ] && is_reserved_intro "${_cmd_words[$i]}"; do i=$((i + 1)); done
  [ "$i" -lt "${#_cmd_words[@]}" ] || return 1
  while [ "$i" -lt "${#_cmd_words[@]}" ]; do
    word_is_dynamic "${_cmd_words[$i]}" && return 0
    word_has_brace_expansion "${_cmd_words[$i]}" && return 0
    name=$(base_name "${_cmd_words[$i]}")
    case "$name" in
      shopt)
        if [ -n "$alias_expand_name" ]; then
          local -n _alias_expand_ref=$alias_expand_name
          update_shopt_alias_state _cmd_words _alias_expand_ref $((i + 1))
        fi
        return 1
        ;;
      alias)
        if [ -n "$alias_names_name" ] && [ -n "$alias_payloads_name" ]; then
          local -n _alias_names_ref=$alias_names_name
          local -n _alias_payloads_ref=$alias_payloads_name
          record_alias_definitions _cmd_words _alias_names_ref _alias_payloads_ref $((i + 1))
        fi
        return 1
        ;;
      command) direct_prefix=1; i=$(skip_command_options _cmd_words $((i + 1))); continue ;;
      builtin) direct_prefix=1; i=$(skip_builtin_options _cmd_words $((i + 1))); continue ;;
      sudo) direct_prefix=1; i=$(skip_sudo_options _cmd_words $((i + 1))); continue ;;
      env)
        env_split_payloads_are_denied _cmd_words $((i + 1)) && return 0
        wrapped=1
        i=$(skip_env_options _cmd_words $((i + 1)))
        continue
        ;;
      exec) wrapped=1; i=$(skip_exec_options _cmd_words $((i + 1))); continue ;;
      busybox|toybox)
        i=$((i + 1))
        [ "$i" -lt "${#_cmd_words[@]}" ] && [ "${_cmd_words[$i]}" = -- ] && i=$((i + 1))
        continue
        ;;
      eval)
        payload=${_cmd_words[*]:$((i + 1))}
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        return 1
        ;;
      bash|sh|zsh|dash|ksh)
        payload=$(literal_payload_after_shell_c _cmd_words $((i + 1)) 2>/dev/null || true)
        [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
        [ "${COMMAND_STDIN_PIPE:-0}" -eq 1 ] && return 0
        shell_here_string_payloads_are_denied original_words original_subs 0 && return 0
        words_have_opaque_stdin_redirection original_words 0 && return 0
        return 1
        ;;
      time|gtime|nohup|setsid|timeout|gtimeout|nice|ionice|chrt|stdbuf|unbuffer)
        wrapped=1
        i=$(skip_wrapper_options _cmd_words $((i + 1)) "$name")
        continue
        ;;
      xargs) xargs_payload_is_denied _cmd_words _cmd_subs $((i + 1)) && return 0; return 1 ;;
    esac
    break
  done
  [ "$i" -lt "${#_cmd_words[@]}" ] || return 1
  word_is_dynamic "${_cmd_words[$i]}" && return 0
  word_has_brace_expansion "${_cmd_words[$i]}" && return 0
  name=$(base_name "${_cmd_words[$i]}")
  if [ -n "$alias_expand_name" ] && [ -n "$alias_names_name" ] && [ -n "$alias_payloads_name" ]; then
    local -n _alias_expand_ref=$alias_expand_name
    local -n _alias_names_ref=$alias_names_name
    local -n _alias_payloads_ref=$alias_payloads_name
    if [ "$_alias_expand_ref" -eq 1 ]; then
      payload=$(alias_payload_for _alias_names_ref _alias_payloads_ref "$name" 2>/dev/null || true)
      [ -n "$payload" ] && command_string_is_denied "$payload" && return 0
    fi
  fi
  case "$name" in
    pkill|killall) return 0 ;;
    fuser)
      local arg
      for arg in "${_cmd_words[@]:$((i + 1))}"; do
        case "$arg" in
          --kill) return 0 ;;
          -?*)
            case "$arg" in
              --*) ;;
              *k*) return 0 ;;
            esac
            ;;
        esac
      done
      ;;
    kill)
      [ "$wrapped" -eq 0 ] || return 0
      validate_kill_args _cmd_words $((i + 1)) || return 0
      ;;
  esac
  [ "$direct_prefix" -eq 1 ] && :
  return 1
}

command_string_is_denied() {
  local src tok
  local current=()
  local current_subs=()
  local stdin_pipe=0
  # shellcheck disable=SC2034
  local alias_expand=0
  # shellcheck disable=SC2034
  local alias_names=()
  # shellcheck disable=SC2034
  local alias_payloads=()
  src=$(redact_non_shell_heredocs "$1")
  tokenize_command "$src" || return 0
  local idx=0 tok
  while [ "$idx" -lt "${#TOKENS[@]}" ]; do
    tok=${TOKENS[$idx]}
    if is_command_separator "$tok"; then
      if [ "${#current[@]}" -gt 0 ]; then
        COMMAND_STDIN_PIPE=$stdin_pipe
        command_words_are_denied current current_subs alias_expand alias_names alias_payloads && return 0
        current=()
        current_subs=()
      fi
      case "$tok" in '|'|'|&') stdin_pipe=1 ;; *) stdin_pipe=0 ;; esac
      idx=$((idx + 1))
      continue
    fi
    current+=("$tok")
    current_subs+=("${TOKEN_SUBS[$idx]:-0}")
    idx=$((idx + 1))
  done
  if [ "${#current[@]}" -gt 0 ]; then
    COMMAND_STDIN_PIPE=$stdin_pipe
    command_words_are_denied current current_subs alias_expand alias_names alias_payloads && return 0
  fi
  return 1
}

command_string_is_denied "$COMMAND" && deny

exit 0
