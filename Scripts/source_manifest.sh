#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT_PATH=${1:?"usage: Scripts/source_manifest.sh OUTPUT_PATH"}
TMP_PATH="$OUTPUT_PATH.tmp.$$"
LIST_PATH="$OUTPUT_PATH.files.$$"

cleanup() {
    rm -f "$TMP_PATH"
    rm -f "$LIST_PATH"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$(dirname "$OUTPUT_PATH")"

(
    cd "$ROOT_DIR"
    if [ -d .git ]; then
        git ls-files -z
    else
        find . -type f \
            -not -path './.build/*' \
            -not -path './dist/*' \
            -not -path './.git/*' -print0
    fi
) > "$LIST_PATH"

unsafe_paths=$(perl -0ne '
    $path = $_;
    chomp $path;
    $path =~ s{^\./}{};
    if ($path =~ /^-/ || $path =~ /[\x00-\x1f\x7f]/) {
        print unpack("H*", $path), "\n";
    }
' "$LIST_PATH")
[ -z "$unsafe_paths" ] || {
    printf 'SOURCE_MANIFEST_FAIL unsafe path encoding (hex):\n%s\n' "$unsafe_paths" >&2
    exit 1
}

(
    cd "$ROOT_DIR"
    tr '\0' '\n' < "$LIST_PATH" | sed 's#^\./##' | LC_ALL=C sort -u | while IFS= read -r relative_path; do
        [ -f "$relative_path" ] || continue
        mode=$(stat -f '%Lp' "$relative_path")
        size=$(stat -f '%z' "$relative_path")
        digest=$(shasum -a 256 "$relative_path" | cut -d ' ' -f 1)
        printf '%s\t%s\t%s\t%s\n' "$mode" "$size" "$digest" "$relative_path"
    done
) > "$TMP_PATH"

mv "$TMP_PATH" "$OUTPUT_PATH"
trap - EXIT HUP INT TERM
rm -f "$LIST_PATH"
chmod 600 "$OUTPUT_PATH"
shasum -a 256 "$OUTPUT_PATH"
