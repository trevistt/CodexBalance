#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_DIR/Scripts/qa_process_guard.sh"
APP_PATH=${1:-"$ROOT_DIR/dist/CodexBalance.app/Contents/MacOS/CodexBalance"}
CYCLES=${2:-20}
EVIDENCE_DIR=${3:-$(mktemp -d "${TMPDIR:-/tmp}/codexbalance-hover-entry.XXXXXX")}
DRIVER_SOURCE="$ROOT_DIR/Scripts/hover_entry_qa.swift"
DRIVER_BINARY="$EVIDENCE_DIR/hover-entry-qa"
APP_PATH=$(CDPATH= cd -- "$(dirname -- "$APP_PATH")" && pwd)/$(basename -- "$APP_PATH")
EXPECTED_HASH=$(shasum -a 256 "$APP_PATH" | awk '{print $1}')
APP_PID=""
DRIVER_PID=""
WATCHDOG_PID=""

mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"

cleanup_app() {
    terminate_pid_bounded "$WATCHDOG_PID" || true
    terminate_pid_bounded "$DRIVER_PID" || true
    terminate_pid_bounded "$APP_PID" || true
    WATCHDOG_PID=""
    DRIVER_PID=""
    APP_PID=""
}

process_path() {
    /usr/sbin/lsof -a -p "$1" -d txt -Fn 2>/dev/null \
        | awk '/^ftxt$/ {found=1; next} found && /^n/ {sub(/^n/,""); print; exit}'
}

wait_for_exact_process_path() {
    target_pid=$1
    expected_path=$2
    attempts=0
    while [ "$attempts" -lt 40 ]; do
        kill -0 "$target_pid" 2>/dev/null || return 1
        observed_path=$(process_path "$target_pid")
        if [ "$observed_path" = "$expected_path" ]; then
            return 0
        fi
        if [ -n "$observed_path" ]; then
            return 1
        fi
        attempts=$((attempts + 1))
        sleep 0.05
    done
    return 1
}
trap cleanup_app EXIT HUP INT TERM

[ -x "$APP_PATH" ] || { echo "HOVER_MATRIX_FAIL app_missing"; exit 2; }
case "$CYCLES" in ''|*[!0-9]*) echo "HOVER_MATRIX_FAIL invalid_cycles"; exit 2;; esac
[ "$CYCLES" -ge 1 ] || { echo "HOVER_MATRIX_FAIL invalid_cycles"; exit 2; }
if pgrep -x CodexBalance >/dev/null 2>&1; then
    echo "HOVER_MATRIX_FAIL existing_codexbalance"
    exit 2
fi

xcrun swiftc -O "$DRIVER_SOURCE" -framework AppKit -framework ApplicationServices -o "$DRIVER_BINARY"
chmod 700 "$DRIVER_BINARY"
printf 'cycle\tresult\tduration_ms\tapp_sha256\tresidual_processes\n' > "$EVIDENCE_DIR/summary.tsv"

cycle=1
while [ "$cycle" -le "$CYCLES" ]; do
    cycle_dir=$(printf '%s/cycle-%02d' "$EVIDENCE_DIR" "$cycle")
    mkdir -p "$cycle_dir"
    chmod 700 "$cycle_dir"
    start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
    nonce=$(uuidgen | tr '[:upper:]' '[:lower:]')
    CODEX_BALANCE_ENABLE_ADAPTIVE_REFRESH=1 \
        "$APP_PATH" "--ui-qa-fixture=$nonce" "--ui-qa-state=success" \
        > "$cycle_dir/app.log" 2>&1 &
    APP_PID=$!
    actual_hash=$(shasum -a 256 "$APP_PATH" | awk '{print $1}')
    result=PASS
    if ! wait_for_exact_process_path "$APP_PID" "$APP_PATH" \
        || [ "$actual_hash" != "$EXPECTED_HASH" ]; then
        result=FAIL_IDENTITY
    else
        "$DRIVER_BINARY" --pid "$APP_PID" --output "$cycle_dir/trace.tsv" \
            > "$cycle_dir/driver.log" 2>&1 &
        DRIVER_PID=$!
        (
            sleep 9
            terminate_pid_bounded "$DRIVER_PID" || true
        ) &
        WATCHDOG_PID=$!
        set +e
        wait "$DRIVER_PID"
        driver_status=$?
        set -e
        DRIVER_PID=""
        terminate_pid_bounded "$WATCHDOG_PID" || true
        WATCHDOG_PID=""
        if [ "$driver_status" -ne 0 ]; then
            result=FAIL_HOVER
        fi
    fi
    cleanup_app
    # SystemUIServer removes the prior NSStatusItem asynchronously. Give the
    # next fixture a clean menu-bar insertion point before measuring hover.
    sleep 1
    residual=$(pgrep -x CodexBalance 2>/dev/null | wc -l | tr -d ' ')
    end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
    duration=$((end_ms - start_ms))
    printf '%s\t%s\t%s\t%s\t%s\n' "$cycle" "$result" "$duration" "$actual_hash" "$residual" \
        >> "$EVIDENCE_DIR/summary.tsv"
    chmod 600 "$cycle_dir"/* 2>/dev/null || true
    if [ "$result" != PASS ] || [ "$residual" -ne 0 ] || [ "$duration" -gt 10000 ]; then
        printf 'HOVER_MATRIX_FAIL cycle=%s result=%s duration_ms=%s residual=%s\n' \
            "$cycle" "$result" "$duration" "$residual"
        exit 1
    fi
    cycle=$((cycle + 1))
done

chmod 600 "$EVIDENCE_DIR/summary.tsv"
printf 'HOVER_MATRIX_PASS cycles=%s app_sha256=%s evidence=%s\n' \
    "$CYCLES" "$EXPECTED_HASH" "$EVIDENCE_DIR"
