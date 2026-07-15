#!/usr/bin/env bash
# Shared watcher session-launcher selection and launch primitives.

fm_watch_session_launcher() {
  if command -v setsid >/dev/null 2>&1; then
    printf '%s\n' setsid
    return 0
  fi
  if command -v perl >/dev/null 2>&1 \
    && perl -MPOSIX=setsid -e 'exit 0' >/dev/null 2>&1; then
    printf '%s\n' perl
    return 0
  fi
  return 1
}

fm_watch_launch_session() {
  local pid_var=$1 output=$2 launcher
  shift 2
  launcher=$(fm_watch_session_launcher) || return 1
  # A new session does not detach file descriptors.
  # Close every arm-task pipe and ignore SIGPIPE before exec so arm, restart,
  # and post-race attach launches survive the harness stopping their parent task.
  case "$launcher" in
    setsid)
      (trap '' PIPE; exec setsid "$@") </dev/null >"$output" 2>&1 &
      ;;
    perl)
      (trap '' PIPE; exec perl -MPOSIX=setsid -e 'setsid() >= 0 or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' "$@") </dev/null >"$output" 2>&1 &
      ;;
    *) return 1 ;;
  esac
  printf -v "$pid_var" '%s' "$!"
}
