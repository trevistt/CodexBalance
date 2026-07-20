#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

output="$(swift run CodexBalanceTestHarness 2>&1)"
printf '%s\n' "$output"

assertions="$(printf '%s\n' "$output" | sed -n 's/.*PASS assertions=\([0-9][0-9]*\).*/\1/p' | tail -1)"
if [ -z "$assertions" ] || [ "$assertions" -le 0 ]; then
    echo "CodexBalance deterministic harness did not report an assertion count." >&2
    exit 1
fi

echo "SCRIPTS_TEST_PASS assertions=$assertions"
