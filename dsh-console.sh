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
#   ./dsh-console.sh stop         # stop the running console (and its watchdog)
#   ./dsh-console.sh watch        # watchdog: auto-restart the console if it dies
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
WATCH_PID_FILE="$LOG_DIR/watchdog.pid"
PORT="${DSH_BEAM_PORT:-4888}"

console_alive() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

watchdog_alive() {
  [ -f "$WATCH_PID_FILE" ] && kill -0 "$(cat "$WATCH_PID_FILE")" 2>/dev/null
}

start_console() {
  mkdir -p "$LOG_DIR"
  : > "$LOG_FILE"   # fresh log each boot; old boots live in crash-audit/session logs
  echo "starting dsh-beam console on 127.0.0.1:$PORT (log: $LOG_FILE)"
  nohup env DSH_BEAM_PORT="$PORT" \
    mix console >> "$LOG_FILE" 2>&1 < /dev/null &
  echo $! > "$PID_FILE"
}

watch_loop() {
  # Loop forever: if the console pid is dead (or the pid file is gone), start
  # a fresh one. Sleeps 5s between checks so a crash loop doesn't hammer the
  # machine. On each restart, notify via macOS notification center when
  # available (osascript), so a silently-died server announces itself.
  while true; do
    if ! console_alive; then
      echo "[watchdog $(date '+%H:%M:%S')] console not running — restarting" >> "$LOG_FILE"
      start_console
      if command -v osascript >/dev/null 2>&1; then
        osascript -e "display notification \"dsh-beam console restarted (pid $(cat "$PID_FILE"))\" with title \"dsh-beam console\"" >/dev/null 2>&1 || true
      fi
    fi
    sleep 5
  done
}

case "${1:-start}" in
  stop)
    if watchdog_alive; then
      echo "stopping watchdog pid $(cat "$WATCH_PID_FILE")"
      kill "$(cat "$WATCH_PID_FILE")" 2>/dev/null || true
      rm -f "$WATCH_PID_FILE"
    fi
    if console_alive; then
      echo "stopping console pid $(cat "$PID_FILE")"
      kill "$(cat "$PID_FILE")" 2>/dev/null || true
      rm -f "$PID_FILE"
    else
      echo "no running console (pid file: $PID_FILE)"
      rm -f "$PID_FILE" 2>/dev/null || true
    fi
    ;;

  logs)
    exec tail -n 50 -f "$LOG_FILE"
    ;;

  watch)
    if watchdog_alive; then
      echo "watchdog already running (pid $(cat "$WATCH_PID_FILE"))"
      exit 0
    fi
    mkdir -p "$LOG_DIR"
    nohup sh -c 'cd "$1"; shift; exec "$@"' sh "$ROOT" "$0" run-watch-loop >> "$LOG_FILE" 2>&1 < /dev/null &
    echo $! > "$WATCH_PID_FILE"
    echo "watchdog pid $(cat "$WATCH_PID_FILE") — console will auto-restart if it dies"
    ;;

  run-watch-loop)
    watch_loop
    ;;

  start)
    if console_alive; then
      echo "console already running (pid $(cat "$PID_FILE"), port $PORT) — $LOG_FILE"
      exit 0
    fi
    start_console
    echo "pid $(cat "$PID_FILE") — follow with: $0 logs"
    ;;

  *)
    echo "usage: $0 [start|stop|watch|logs]" >&2
    exit 2
    ;;
esac
