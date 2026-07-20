#!/bin/sh
set -eu

LABEL="app.codexbalance.local"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LAUNCHER="$ROOT_DIR/Scripts/run_practical.sh"
APP_DIR="$ROOT_DIR/dist/CodexBalance.app"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="${CODEX_BALANCE_OPEN_AT_LOGIN_PLIST_OUTPUT:-$PLIST_DIR/$LABEL.plist}"
LOG_DIR="$HOME/Library/Logs/CodexBalance"
BACKUP_DIR="$HOME/Library/Application Support/CodexBalance/OpenAtLogin"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"

if [ "$(id -u)" -eq 0 ]; then
    echo "Open at Login is a user service and must not use sudo." >&2
    exit 1
fi
if [ ! -x "$LAUNCHER" ]; then
    echo "Daily launcher is missing or not executable: $LAUNCHER" >&2
    exit 1
fi
if [ ! -d "$APP_DIR" ]; then
    echo "Packaged app is missing: $APP_DIR" >&2
    exit 1
fi

xml_escape() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

mkdir -p "$(dirname "$PLIST")"
APP_XML=$(xml_escape "$APP_DIR")
OUT_XML=$(xml_escape "$LOG_DIR/open-at-login.out.log")
ERR_XML=$(xml_escape "$LOG_DIR/open-at-login.err.log")
TMP_PLIST="$PLIST.tmp.$$"

cat > "$TMP_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-g</string>
        <string>$APP_XML</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$OUT_XML</string>
    <key>StandardErrorPath</key>
    <string>$ERR_XML</string>
</dict>
</plist>
EOF
plutil -lint "$TMP_PLIST" >/dev/null
chmod 644 "$TMP_PLIST"

if [ -n "${CODEX_BALANCE_OPEN_AT_LOGIN_PLIST_OUTPUT:-}" ]; then
    mv "$TMP_PLIST" "$PLIST"
    echo "Open at Login candidate rendered: $PLIST"
    exit 0
fi

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
if [ -f "$PLIST" ]; then
    cp -p "$PLIST" "$BACKUP_DIR/$LABEL.previous.plist"
    chmod 600 "$BACKUP_DIR/$LABEL.previous.plist"
fi

launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
launchctl bootout "$DOMAIN" "$PLIST" >/dev/null 2>&1 || true
mv "$TMP_PLIST" "$PLIST"
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl kickstart -k "$SERVICE"

echo "Open at Login enabled: $PLIST"
echo "Service: $SERVICE"
echo "Starts after macOS login and does not use KeepAlive."
echo "Logs: $LOG_DIR"
