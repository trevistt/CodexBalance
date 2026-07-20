#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/dist/CodexBalance.app"
APP_BIN="$ROOT_DIR/dist/CodexBalance.app/Contents/MacOS/CodexBalance"
LOG_DIR="${CODEX_BALANCE_LOG_DIR:-$HOME/Library/Logs/CodexBalance}"
LOG_FILE="$LOG_DIR/practical.log"
LOCK_DIR="$LOG_DIR/run-practical.lock"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S %Z'
}

log() {
    printf '%s %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
}

mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "Another launcher invocation is active; duplicate start skipped."
    echo "CodexBalance is already starting."
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT HUP INT TERM

if [ ! -x "$APP_BIN" ]; then
    log "ERROR packaged app binary is missing."
    echo "Package CodexBalance first with Scripts/package_app.sh." >&2
    exit 1
fi

running_pids="$(pgrep -x CodexBalance || true)"
if [ -n "$running_pids" ]; then
    log "Already running; duplicate start skipped. PIDs: $running_pids"
    echo "CodexBalance is already running."
    exit 0
fi

unset CODEX_BALANCE_FIXTURE
unset CODEX_BALANCE_ANALYTICS_FIXTURE

log "Starting Codex-only daily app."
if [ "${CODEX_BALANCE_SHOW_NOTCH:-0}" = "1" ]; then
    /usr/bin/open -g --env CODEX_BALANCE_SHOW_NOTCH=1 "$APP_DIR"
else
    /usr/bin/open -g "$APP_DIR"
fi

sleep 2
started_pids="$(pgrep -x CodexBalance || true)"
if [ -z "$started_pids" ]; then
    log "ERROR launch returned without a running app."
    echo "CodexBalance did not remain running. See $LOG_FILE." >&2
    exit 1
fi

log "Started. PIDs: $started_pids"
echo "CodexBalance is running."
echo "Log: $LOG_FILE"
