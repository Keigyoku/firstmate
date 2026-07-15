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
  local pid_var=$1 identity_var=$2 output=$3 launcher helper pid_file identity_file launched_pid launched_identity
  shift 3
  launcher=$(fm_watch_session_launcher) || return 1
  pid_file="${output}.pid"
  identity_file="${output}.identity"
  rm -f "$pid_file" "$identity_file" 2>/dev/null || return 1
  # A new session and detached descriptors are not enough for task managers that
  # discover and kill descendants by walking /proc.  Launch through a short-lived
  # session leader so the watcher is orphaned before this function returns.
  # The pid-and-identity handoff preserves the arm script's confirmation and
  # monitoring contracts without risking a recycled pid.
  case "$launcher" in
    setsid)
      (
        trap '' PIPE
        # shellcheck disable=SC2016 # Positional parameters expand in the inner shell.
        exec setsid sh -c '
          pid_file=$1
          identity_file=$2
          output=$3
          shift 3
          trap "" PIPE
          FM_WATCH_LAUNCH_IDENTITY_FILE=$identity_file "$@" </dev/null >"$output" 2>&1 &
          child=$!
          attempts=0
          while [ ! -s "$identity_file" ] && kill -0 "$child" 2>/dev/null && [ "$attempts" -lt 1000 ]; do
            sleep 0.01
            attempts=$((attempts + 1))
          done
          if [ ! -s "$identity_file" ]; then
            kill -TERM "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
            exit 1
          fi
          if ! printf "%s\n" "$child" >"$pid_file"; then
            kill -TERM "$child" 2>/dev/null || true
            wait "$child" 2>/dev/null || true
            exit 1
          fi
        ' sh "$pid_file" "$identity_file" "$output" "$@"
      ) </dev/null >/dev/null 2>&1 &
      ;;
    perl)
      (
        trap '' PIPE
        exec perl -MPOSIX=setsid -e '
          my ($pid_file, $identity_file, $output, @command) = @ARGV;
          setsid() >= 0 or die "setsid: $!\n";
          my $pid = fork();
          defined $pid or die "fork: $!\n";
          if ($pid) {
            my $attempts = 0;
            while (!-s $identity_file && kill(0, $pid) && $attempts < 1000) {
              select undef, undef, undef, 0.01;
              $attempts++;
            }
            if (!-s $identity_file) {
              kill "TERM", $pid;
              waitpid $pid, 0;
              die "identity handoff failed\n";
            }
            my $handoff = eval {
              open my $fh, ">", $pid_file or die "open $pid_file: $!\n";
              print {$fh} "$pid\n" or die "write $pid_file: $!\n";
              close $fh or die "close $pid_file: $!\n";
              1;
            };
            if (!$handoff) {
              kill "TERM", $pid;
              waitpid $pid, 0;
              die $@;
            }
            exit 0;
          }
          $ENV{FM_WATCH_LAUNCH_IDENTITY_FILE} = $identity_file;
          open STDIN, "<", "/dev/null" or die "stdin: $!\n";
          open STDOUT, ">", $output or die "stdout: $!\n";
          open STDERR, ">&", \*STDOUT or die "stderr: $!\n";
          $SIG{PIPE} = "IGNORE";
          exec @command or die "exec: $!\n";
        ' "$pid_file" "$identity_file" "$output" "$@"
      ) </dev/null >/dev/null 2>&1 &
      ;;
    *) return 1 ;;
  esac
  helper=$!
  if ! wait "$helper" || [ ! -s "$pid_file" ]; then
    rm -f "$pid_file" "$identity_file" 2>/dev/null || true
    return 1
  fi
  launched_pid=$(cat "$pid_file" 2>/dev/null || true)
  launched_identity=$(cat "$identity_file" 2>/dev/null || true)
  rm -f "$pid_file" "$identity_file" 2>/dev/null || true
  case "$launched_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ -n "$launched_identity" ] || return 1
  printf -v "$pid_var" '%s' "$launched_pid"
  printf -v "$identity_var" '%s' "$launched_identity"
}
