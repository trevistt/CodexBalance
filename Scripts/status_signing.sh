#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/dist/CodexBalance.app"

if [ ! -d "$APP_DIR" ]; then
    echo "Signing: app not found at $APP_DIR" >&2
    exit 1
fi

codesign -dvvv "$APP_DIR" 2>&1 | sed -n \
    '/^Identifier=/p;/^Signature=/p;/^Authority=/p;/^TeamIdentifier=/p'
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "Signing verification: PASS"
