#!/usr/bin/env bash
# PATH defense installed under the names pkill, killall, and fuser by fm-spawn.sh.
printf '%s\n' 'crew-kill-guard: process signaling by pattern or sweep is denied. Only kill/kill -<signal> of individually verified explicit numeric PIDs owned by this task is allowed. The live app, desktop session, and herdr processes are untouchable. Escalate instead of retrying a variant.' >&2
exit 126
