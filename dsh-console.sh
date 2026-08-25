#!/bin/sh
# dsh-console.sh — run the dsh-beam live console detached from the parent
# process, so it survives the shell/agent-browser job that launched it.
#
# Why detached: the console died twice when its stdout/stderr pipe went away
# (an "agent browser background job" ending closed the pipe; the VM crashed at
# boot with "the device does not exist"). Redirecting stdio to a file + nohup
# + </dev/null decouples the console from the parent's lifetime.
#
# Usage:
#   ./dsh-console.sh              # default port (4888)
#   DSH_BEAM_PORT=5000 ./dsh-console.sh
#   ./dsh-console.sh stop         # stop the running console
#   ./dsh-console.sh logs         # tail the console log
#
# The log lives under .dsh/ (gitignored), so it never pollutes the repo.

set -eu

# Project root = this script's directory, so it works from any cwd.
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/.dsh"
LOG_FILE="$LOG_DIR/console.log"
PID_FILE="$LOG_DIR/console.pid"
PORT="${DSH_BEAM_PORT:-4888}"

case "${1:-start}" in
  stop)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "stopping console pid $(cat "$PID_FILE")"
      kill "$(cat "$PID_FILE")"
      rm -f "$PID_FILE"
    else
      echo "no running console (pid file: $PID_FILE)"
    fi
    ;;

  logs)
    exec tail -n 50 -f "$LOG_FILE"
    ;;

  start)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "console already running (pid $(cat "$PID_FILE"), port $PORT) — $LOG_FILE"
      exit 0
    fi

    mkdir -p "$LOG_DIR"
    : > "$LOG_FILE"   # fresh log each boot; old boots live in crash-audit/session logs

    echo "starting dsh-beam console on 127.0.0.1:$PORT (log: $LOG_FILE)"
    nohup env DSH_BEAM_PORT="$PORT" \
      mix console >> "$LOG_FILE" 2>&1 < /dev/null &

    echo $! > "$PID_FILE"
    echo "pid $(cat "$PID_FILE") — follow with: $0 logs"
    ;;

  *)
    echo "usage: $0 [start|stop|logs]" >&2
    exit 2
    ;;
esac
