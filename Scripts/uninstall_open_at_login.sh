#!/bin/sh
set -eu

LABEL="app.codexbalance.local"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "$(id -u)" -eq 0 ]; then
    echo "Do not uninstall Open at Login with sudo or as root."
    exit 1
fi

launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "Open at Login disabled: $PLIST"
echo "Logs were left in place at: $HOME/Library/Logs/CodexBalance"
