#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ROOT_VIEW="$ROOT_DIR/Sources/CodexBalance/HoverPanelView.swift"
TOKENS="$ROOT_DIR/Sources/CodexBalance/DashboardDesignTokens.swift"
PRESENTATION="$ROOT_DIR/Sources/CodexBalance/DashboardPresentation.swift"
MATERIAL="$ROOT_DIR/Sources/CodexBalance/DashboardMaterialSurface.swift"
RUNWAY="$ROOT_DIR/Sources/CodexBalance/DashboardRunwayViews.swift"
FOOTER="$ROOT_DIR/Sources/CodexBalance/DashboardDetailsFooterViews.swift"
AX_DRIVER="$ROOT_DIR/Scripts/ui_qa_accessibility.swift"

contains() {
    file=$1
    pattern=$2
    [ -f "$file" ] && grep -Fq "$pattern" "$file"
}

baseline_gap() {
    label=$1
    shift
    if "$@"; then
        printf 'AM0_GAP_PASS %s\n' "$label"
        return
    fi
    printf 'AM0_GAP_FAIL missing expected V1 gap: %s\n' "$label" >&2
    exit 1
}

require() {
    file=$1
    pattern=$2
    label=$3
    if ! contains "$file" "$pattern"; then
        printf 'APPLE_MATERIAL_CONTRACT_FAIL missing: %s\n' "$label" >&2
        exit 1
    fi
    printf 'PASS %s\n' "$label"
}

forbid() {
    file=$1
    pattern=$2
    label=$3
    if contains "$file" "$pattern"; then
        printf 'APPLE_MATERIAL_CONTRACT_FAIL forbidden: %s\n' "$label" >&2
        exit 1
    fi
    printf 'PASS %s\n' "$label"
}

if [ "${1:-}" = "--baseline" ]; then
    baseline_gap 'hard-coded opaque RGB shell exists' contains "$TOKENS" 'calibratedRed: 0.055'
    baseline_gap 'semantic popover material is absent' sh -c "! grep -R -Fq 'material = .popover' '$ROOT_DIR/Sources/CodexBalance'"
    baseline_gap 'display accessibility seams are absent' sh -c "! grep -R -Fq 'DashboardDisplayAccessibility' '$ROOT_DIR/Sources/CodexBalance'"
    baseline_gap 'runway presentation is absent' sh -c "! grep -R -Fq 'DashboardRunwayPresentation' '$ROOT_DIR/Sources/CodexBalance'"
    baseline_gap 'Today-versus-normal presentation is absent' sh -c "! grep -R -Fq 'TodayVsNormalPresentation' '$ROOT_DIR/Sources/CodexBalance'"
    baseline_gap 'old 392pt panel width is present' contains "$ROOT_VIEW" 'panelWidth: CGFloat = 392'
    baseline_gap 'old 720pt natural height is present' contains "$ROOT_VIEW" 'naturalHeight: CGFloat = 720'
    baseline_gap 'quota cards are repeated per row' contains "$ROOT_DIR/Sources/CodexBalance/DashboardQuotaViews.swift" 'DashboardQuotaCard(row:'
    printf 'AM0_FAILING_BEFORE_PASS assertions=8\n'
    exit 0
fi

require "$MATERIAL" 'NSVisualEffectView' 'narrow AppKit visual-effect bridge'
require "$MATERIAL" 'material = .popover' 'semantic popover material'
require "$MATERIAL" 'blendingMode = .behindWindow' 'behind-window production blending'
require "$MATERIAL" 'DashboardDisplayAccessibility' 'deterministic display-accessibility seam'
require "$ROOT_VIEW" 'panelWidth: CGFloat = 376' 'planned narrow width'
require "$ROOT_VIEW" 'naturalHeight: CGFloat = 860' 'expanded natural height'
require "$ROOT_VIEW" 'DashboardMaterialSurface' 'material hosts the SwiftUI shell'
require "$RUNWAY" 'DashboardRunwayPresentation' 'runway presentation exists'
require "$PRESENTATION" 'TodayVsNormalPresentation' 'truthful activity comparison exists'
require "$PRESENTATION" 'minimumComparableDays = 3' 'comparison requires three prior days'
require "$PRESENTATION" 'prefix(7)' 'comparison is bounded to seven prior days'
require "$ROOT_VIEW" 'DashboardHeaderView' 'header remains fixed outside body scroll'
require "$ROOT_VIEW" 'DashboardFooterView' 'footer remains fixed outside body scroll'
require "$ROOT_VIEW" 'Refresh unavailable.' 'manual refresh explains an idle pause'
require "$FOOTER" 'refreshFeedback' 'refresh feedback is exposed through accessibility'
require "$FOOTER" '.frame(width: 74, height: 28)' 'Refresh label width prevents truncation'
require "$FOOTER" '.frame(width: 64, height: 28)' 'Unpin label width prevents truncation'
require "$TOKENS" 'static let safeText' 'status text is separate from chart accent'
require "$TOKENS" 'static let cautionText' 'warning text is separate from chart accent'
require "$AX_DRIVER" 'displayBounds(containing:' 'soak verifies visible display containment'
require "$AX_DRIVER" 'PASS post-soak Tab, Shift-Tab, Space, Return, and Command-R paths' 'full keyboard path is reverified after soak'
forbid "$TOKENS" 'calibratedRed: 0.055' 'opaque hard-coded V1 root removed'
printf 'APPLE_MATERIAL_CONTRACT_PASS assertions=22\n'
