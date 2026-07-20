#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_NAME="CodexBalance"
BUNDLE_ID="app.codexbalance.local"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
STAGE_APP_DIR="$DIST_DIR/.$APP_NAME.app.stage.$$"
SCRATCH_DIR="/tmp/codex-balance-package-build.$$"
CONTENTS_DIR="$STAGE_APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BINARY_NAME="CodexBalance"
CODESIGN_IDENTITY="${CODEX_BALANCE_CODESIGN_IDENTITY:--}"
REQUIRE_STABLE_SIGNING="${CODEX_BALANCE_REQUIRE_STABLE_SIGNING:-0}"

cleanup() {
    rm -rf "$STAGE_APP_DIR"
    rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT HUP INT TERM

cd "$ROOT_DIR"
swift build -c release --scratch-path "$SCRATCH_DIR" --product "$BINARY_NAME"

rm -rf "$STAGE_APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SCRATCH_DIR/release/$BINARY_NAME" "$MACOS_DIR/$BINARY_NAME"
chmod 755 "$MACOS_DIR/$BINARY_NAME"
strip -S "$MACOS_DIR/$BINARY_NAME"

private_binary_pattern='/Users/[^/[:space:]]+/(Library/Cloud[S]torage|Desktop|Documents)/|One[D]rive-[P]ersonal|Tre[v]is[[:space:]]*&[[:space:]]*Sherr[y]|/(var/folders/[^[:space:]]+|tmp)/codex-balance-package-build'
if rg -a -l -i -- "$private_binary_pattern" "$MACOS_DIR/$BINARY_NAME" >/dev/null 2>&1; then
    echo "Packaged executable contains a private build path." >&2
    exit 1
fi

RESOURCE_BUNDLE="$SCRATCH_DIR/release/CodexBalance_CodexBalance.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

if [ ! -d "$RESOURCES_DIR/CodexBalance_CodexBalance.bundle" ]; then
    echo "Packaged SwiftPM resource bundle is missing." >&2
    exit 1
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$BINARY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Codex Balance</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"

if [ "$REQUIRE_STABLE_SIGNING" = "1" ] && [ "$CODESIGN_IDENTITY" = "-" ]; then
    echo "A stable existing signing identity is required but was not provided." >&2
    exit 1
fi

codesign --force --deep --sign "$CODESIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --timestamp=none \
    "$STAGE_APP_DIR"
codesign --verify --deep --strict --verbose=2 "$STAGE_APP_DIR"

rm -rf "$APP_DIR"
mv "$STAGE_APP_DIR" "$APP_DIR"
trap - EXIT HUP INT TERM

echo "Packaged app: $APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | sed -n '/^Identifier=/p;/^Signature=/p;/^Authority=/p;/^TeamIdentifier=/p'
