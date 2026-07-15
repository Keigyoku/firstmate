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
  local pid_var=$1 output=$2 launcher helper pid_file launched_pid
  shift 2
  launcher=$(fm_watch_session_launcher) || return 1
  pid_file="${output}.pid"
  rm -f "$pid_file" 2>/dev/null || return 1
  # A new session and detached descriptors are not enough for task managers that
  # discover and kill descendants by walking /proc.  Launch through a short-lived
  # session leader so the watcher is orphaned before this function returns.
  # The pid handoff preserves the arm script's confirmation and wait contracts.
  case "$launcher" in
    setsid)
      (
        trap '' PIPE
        # shellcheck disable=SC2016 # Positional parameters expand in the inner shell.
        exec setsid sh -c '
          pid_file=$1
          output=$2
          shift 2
          trap "" PIPE
          "$@" </dev/null >"$output" 2>&1 &
          printf "%s\n" "$!" >"$pid_file"
        ' sh "$pid_file" "$output" "$@"
      ) </dev/null >/dev/null 2>&1 &
      ;;
    perl)
      (
        trap '' PIPE
        exec perl -MPOSIX=setsid -e '
          my ($pid_file, $output, @command) = @ARGV;
          setsid() >= 0 or die "setsid: $!\n";
          my $pid = fork();
          defined $pid or die "fork: $!\n";
          if ($pid) {
            open my $fh, ">", $pid_file or die "open $pid_file: $!\n";
            print {$fh} "$pid\n" or die "write $pid_file: $!\n";
            close $fh or die "close $pid_file: $!\n";
            exit 0;
          }
          open STDIN, "<", "/dev/null" or die "stdin: $!\n";
          open STDOUT, ">", $output or die "stdout: $!\n";
          open STDERR, ">&", \*STDOUT or die "stderr: $!\n";
          $SIG{PIPE} = "IGNORE";
          exec @command or die "exec: $!\n";
        ' "$pid_file" "$output" "$@"
      ) </dev/null >/dev/null 2>&1 &
      ;;
    *) return 1 ;;
  esac
  helper=$!
  if ! wait "$helper" || [ ! -s "$pid_file" ]; then
    rm -f "$pid_file" 2>/dev/null || true
    return 1
  fi
  launched_pid=$(cat "$pid_file" 2>/dev/null || true)
  rm -f "$pid_file" 2>/dev/null || true
  case "$launched_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf -v "$pid_var" '%s' "$launched_pid"
}
