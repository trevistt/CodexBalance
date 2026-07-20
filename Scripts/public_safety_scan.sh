#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

scan_files() {
    if [ -d .git ]; then
        git ls-files -z
    else
        find . -type f \
            -not -path './.build/*' \
            -not -path './dist/*' \
            -not -path './.git/*' -print0
    fi
}

file_count=$(scan_files | tr -cd '\0' | wc -c | tr -d ' ')
[ "$file_count" -gt 0 ] || { echo "PUBLIC_SAFETY_FAIL no files" >&2; exit 1; }

unsafe_paths=$(scan_files | perl -0ne '
    $path = $_;
    chomp $path;
    $path =~ s{^\./}{};
    if ($path =~ /^-/ || $path =~ /[\x00-\x1f\x7f]/) {
        print unpack("H*", $path), "\n";
    }
')
[ -z "$unsafe_paths" ] || {
    printf 'PUBLIC_SAFETY_FAIL unsafe path encoding (hex):\n%s\n' "$unsafe_paths" >&2
    exit 1
}

legacy_pattern='Quota[P]ulse|quota[-_ ]?p[u]lse|com\.tre[v]is|CODEX_NOTCH_[M]ETER|CodexNotch[M]eter|Clau[d]e|Anthr[o]pic|Codex[B]ar|Codex[ ]Bar|Notch[y]'
legacy_hits=$(scan_files | xargs -0 rg -l -i "$legacy_pattern" -- 2>/dev/null || true)
unexpected_legacy=$(printf '%s\n' "$legacy_hits" \
    | sed '/^$/d;/^\.\/THIRD_PARTY_NOTICES\.md$/d;/^THIRD_PARTY_NOTICES\.md$/d')
[ -z "$unexpected_legacy" ] || {
    printf 'PUBLIC_SAFETY_FAIL legacy names:\n%s\n' "$unexpected_legacy" >&2
    exit 1
}

private_pattern='/Users/[^/[:space:]]+/(Library/CloudStorage|Desktop|Documents)/|One[D]rive-[P]ersonal|Tre[v]is[[:space:]]*&[[:space:]]*Sherr[y]|docs/c[o]dex|\.project-[o]s|Current[R]un'
private_hits=$(scan_files | xargs -0 rg -l -i "$private_pattern" -- 2>/dev/null || true)
[ -z "$private_hits" ] || {
    printf 'PUBLIC_SAFETY_FAIL private paths/state:\n%s\n' "$private_hits" >&2
    exit 1
}

secret_pattern='BEGIN [A-Z ]*PRIVATE KEY|github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{24,}'
secret_hits=$(scan_files | xargs -0 rg -l "$secret_pattern" -- 2>/dev/null || true)
[ -z "$secret_hits" ] || {
    printf 'PUBLIC_SAFETY_FAIL secret-like values:\n%s\n' "$secret_hits" >&2
    exit 1
}

generated=$(scan_files | tr '\0' '\n' | rg '(^|/)(\.build|dist)/|\.app/|\.(log|xcresult)$' || true)
[ -z "$generated" ] || {
    printf 'PUBLIC_SAFETY_FAIL generated artifacts:\n%s\n' "$generated" >&2
    exit 1
}

symlinks=$(find . -type l \
    -not -path './.git/*' \
    -not -path './.build/*' \
    -not -path './dist/*' -print)
[ -z "$symlinks" ] || {
    printf 'PUBLIC_SAFETY_FAIL symlinks:\n%s\n' "$symlinks" >&2
    exit 1
}

echo "PUBLIC_SAFETY_PASS files=$file_count"
