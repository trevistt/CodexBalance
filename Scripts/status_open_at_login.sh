#!/bin/sh
set -eu

LABEL="app.codexbalance.local"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SERVICE="gui/$(id -u)/$LABEL"

if [ -f "$PLIST" ]; then
    echo "Open at Login: installed ($PLIST)"
    plutil -lint "$PLIST"
else
    echo "Open at Login: not installed"
fi

if launchctl print "$SERVICE" >/dev/null 2>&1; then
    echo "Service: loaded ($SERVICE)"
else
    echo "Service: not loaded ($SERVICE)"
fi

running_pids="$(pgrep -x CodexBalance || true)"
if [ -n "$running_pids" ]; then
    echo "App: running ($running_pids)"
else
    echo "App: not running"
fi
