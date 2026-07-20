#!/bin/sh

wait_pid_exit_bounded() {
    guard_pid=$1
    guard_steps=${2:-20}
    guard_step=0
    while kill -0 "$guard_pid" 2>/dev/null && [ "$guard_step" -lt "$guard_steps" ]; do
        sleep 0.1
        guard_step=$((guard_step + 1))
    done
    ! kill -0 "$guard_pid" 2>/dev/null
}

terminate_pid_bounded() {
    guard_pid=$1
    [ -n "$guard_pid" ] || return 0
    if kill -0 "$guard_pid" 2>/dev/null; then
        kill "$guard_pid" 2>/dev/null || true
        if ! wait_pid_exit_bounded "$guard_pid" 10; then
            kill -9 "$guard_pid" 2>/dev/null || true
            wait_pid_exit_bounded "$guard_pid" 10 || return 1
        fi
    fi
    wait "$guard_pid" 2>/dev/null || true
    ! kill -0 "$guard_pid" 2>/dev/null
}
