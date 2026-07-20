# Architecture

Codex Balance is a SwiftPM macOS package with three executable/library seams:

- `CodexBalanceCore`: providers, source ordering, refresh policy, snapshots,
  decisions, analytics, caches, and diagnostics
- `CodexBalance`: AppKit status item and panel hosting SwiftUI dashboard views
- `CodexBalanceTestHarness`: deterministic credential-free behavioral checks

Quota sources are tried in order: direct OAuth usage request, Codex CLI
app-server RPC, then local session-log usage windows. The first complete result
wins; windows from different sources are never merged.

Adaptive Refresh is enabled by default. It is single-flight, presence-aware,
jittered, and cooldown-aware. Set `CODEX_BALANCE_ENABLE_ADAPTIVE_REFRESH=0`
for manual scheduling during local diagnosis.

The dashboard panel is anchored to the visible status item, clamped to the
selected screen's visible frame, and repositions after content or status-item
changes. Hover opens are idempotent; click, Pin, keyboard, and body scrolling
share one retained panel controller.

Runtime state is new and isolated: bundle/OAL ID `app.codexbalance.local`,
environment prefix `CODEX_BALANCE_`, and cache/preferences/log namespace
`CodexBalance`. There is no migration or cleanup of another product's state.
