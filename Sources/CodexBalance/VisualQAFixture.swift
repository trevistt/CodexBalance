import AppKit
import CodexBalanceCore
import SwiftUI

enum VisualQAVariant: String, CaseIterable {
    case sessionWeekly = "session-weekly"
    case weeklyOnly = "weekly-only"
    case loading
    case liveUnchanged = "live-unchanged"
    case liveChanged = "live-changed"
    case refreshingCache = "refreshing-cache"
    case stale
    case authBlocked = "auth-blocked"
    case rateLimited = "rate-limited"
    case unavailable
    case error
    case extraWindow = "extra-window"
    case fullAnalytics = "full-analytics"
    case analyticsUnavailable = "analytics-unavailable"
    case analyticsPartial = "analytics-partial"
    case tall
    case constrained
    case baselineInsufficient = "baseline-insufficient"
    case reduceTransparency = "reduce-transparency"
    case increaseContrast = "increase-contrast"
    case reduceMotion = "reduce-motion"
    case backdropLight = "backdrop-light"
    case backdropDark = "backdrop-dark"
    case backdropColorful = "backdrop-colorful"
    case runwaySafe = "runway-safe"
    case missingReset = "missing-reset"
    case detailsExpanded = "details-expanded"
}

@MainActor
enum VisualQAFixtureRunner {
    static func run(outputURL: URL, variant: VisualQAVariant) -> Bool {
        let now = Date()
        let nonce = UUID().uuidString
        let usageStore = UsageStore(
            provider: FixtureCodexUsageProvider(now: { now }),
            cache: UsageSnapshotCache(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-balance-visual-\(nonce)-usage.json")))
        let analyticsStore = LocalUsageAnalyticsStore(
            provider: FixtureLocalUsageAnalyticsProvider(now: { now }),
            cache: LocalUsageAnalyticsCache(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-balance-visual-\(nonce)-analytics.json")))
        let targetSnapshot = self.snapshot(variant: variant, now: now)
        let targetAnalytics = self.analytics(variant: variant, now: now)
        usageStore.replaceSnapshotForTesting(targetSnapshot)
        usageStore.setRefreshingForTesting(variant == .loading || variant == .refreshingCache)
        var observations = UsageObservationState()
        _ = observations.recordVerified(targetSnapshot, at: now.addingTimeInterval(-20))
        if variant == .liveChanged {
            let prior = UsageSnapshot(
                sessionPercentRemaining: 68,
                weeklyPercentRemaining: 44,
                sessionResetAt: targetSnapshot.sessionResetAt,
                weeklyResetAt: targetSnapshot.weeklyResetAt,
                source: .fixture,
                updatedAt: now.addingTimeInterval(-10))
            _ = observations.recordVerified(prior, at: now.addingTimeInterval(-10))
            _ = observations.recordVerified(targetSnapshot, at: now)
        }
        usageStore.replaceObservationStateForTesting(observations)
        analyticsStore.replaceSnapshotForTesting(targetAnalytics)

        let scheduler = RefreshScheduler(
            store: usageStore,
            defaults: UserDefaults(suiteName: "CodexBalance.VisualQA.\(nonce)")!,
            now: { now },
            jitterUnit: { 0.5 })
        let analyticsScheduler = LocalUsageAnalyticsScheduler(store: analyticsStore)
        let pinState = DashboardPinState(defaults: UserDefaults(suiteName: "CodexBalance.VisualQA.Pin.\(nonce)")!)
        let requestedMax: CGFloat = variant == .constrained ? 540 : HoverPanelView.naturalHeight
        let panelHeight = HoverPanelView.preferredHeight(
            snapshot: targetSnapshot,
            analytics: targetAnalytics,
            maxHeight: requestedMax)
        let canvasSize = NSSize(width: 680, height: panelHeight + 90)
        let displayAccessibility = self.displayAccessibility(variant: variant)
        let panelView = HoverPanelView(
            usageStore: usageStore,
            scheduler: scheduler,
            analyticsStore: analyticsStore,
            analyticsScheduler: analyticsScheduler,
            pinState: pinState,
            maxHeight: panelHeight,
            displayAccessibility: displayAccessibility,
            initialDetailsExpanded: variant == .detailsExpanded,
            onQuit: {})
        let presentation = UsageDisplayFormatter.menuBarPresentation(
            snapshot: targetSnapshot,
            isRefreshing: variant == .loading,
            now: now)
        let preview = VStack(spacing: 10) {
            VisualMenuBarMock(presentation: presentation)
                .frame(width: 80, height: 30)
                .background(Color.black.opacity(0.9))
                .overlay(Rectangle().stroke(Color.white.opacity(0.18), lineWidth: 1))
            panelView
                .overlay(Rectangle().stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1))
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color.clear)
        .environment(\.colorScheme, self.colorScheme(variant: variant))
        let hosting = NSHostingController(rootView: preview)
        hosting.view.frame = NSRect(origin: .zero, size: canvasSize)

        let backdropHosting = NSHostingController(rootView: VisualQABackdrop(variant: variant))
        backdropHosting.view.frame = NSRect(origin: .zero, size: canvasSize)
        let container = NSView(frame: NSRect(origin: .zero, size: canvasSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(backdropHosting.view)
        container.addSubview(hosting.view)
        let backdropWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        backdropWindow.appearance = NSAppearance(named: self.colorScheme(variant: variant) == .light ? .aqua : .darkAqua)
        backdropWindow.isOpaque = true
        backdropWindow.contentViewController = backdropHosting

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: canvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        window.appearance = NSAppearance(named: self.colorScheme(variant: variant) == .light ? .aqua : .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.level = .floating
        window.contentView = container

        if let visible = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: visible.midX - canvasSize.width / 2,
                y: visible.midY - canvasSize.height / 2)
            backdropWindow.setFrameOrigin(origin)
            window.setFrameOrigin(origin)
        }
        backdropWindow.orderFrontRegardless()
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.view.layoutSubtreeIfNeeded()
        if variant == .detailsExpanded {
            self.scrollFirstScrollViewToBottom(in: hosting.view)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            hosting.view.layoutSubtreeIfNeeded()
        }
        hosting.view.displayIfNeeded()
        window.displayIfNeeded()
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            guard let representation = container.bitmapImageRepForCachingDisplay(
                in: container.bounds)
            else { throw CocoaError(.fileWriteUnknown) }
            container.cacheDisplay(in: container.bounds, to: representation)
            guard let data = representation.representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: outputURL, options: .atomic)
            guard let size = try FileManager.default
                .attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber,
                  size.intValue > 0
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            window.orderOut(nil)
            backdropWindow.orderOut(nil)
            print("VISUAL_QA_PASS variant=\(variant.rawValue) path=\(outputURL.path) bytes=\(size.intValue)")
            return true
        } catch {
            window.orderOut(nil)
            backdropWindow.orderOut(nil)
            fputs("visual QA failed: \(UsageSnapshot.sanitized(error.localizedDescription))\n", stderr)
            return false
        }
    }

    private static func scrollFirstScrollViewToBottom(in view: NSView) {
        if let scrollView = view as? NSScrollView,
           let documentView = scrollView.documentView
        {
            let maximumY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        for subview in view.subviews {
            let before = subview.enclosingScrollView?.contentView.bounds.origin
            self.scrollFirstScrollViewToBottom(in: subview)
            if subview.enclosingScrollView?.contentView.bounds.origin != before { return }
        }
    }

    private static func displayAccessibility(variant: VisualQAVariant) -> DashboardDisplayAccessibility {
        DashboardDisplayAccessibility(
            reduceTransparency: variant == .reduceTransparency,
            increaseContrast: variant == .increaseContrast,
            reduceMotion: variant == .reduceMotion,
            useWithinWindowBlending: false)
    }

    private static func colorScheme(variant: VisualQAVariant) -> ColorScheme {
        variant == .backdropLight ? .light : .dark
    }

    private static func snapshot(variant: VisualQAVariant, now: Date) -> UsageSnapshot {
        let base = UsageSnapshot(
            sessionPercentRemaining: 63,
            weeklyPercentRemaining: 39,
            sessionResetAt: now.addingTimeInterval(2 * 3_600 + 20 * 60),
            weeklyResetAt: now.addingTimeInterval(3 * 86_400 + 5 * 3_600),
            source: .fixture,
            updatedAt: now)
        switch variant {
        case .weeklyOnly:
            return UsageSnapshot(
                sessionPercentRemaining: nil,
                weeklyPercentRemaining: 43,
                sessionResetAt: nil,
                weeklyResetAt: now.addingTimeInterval(4 * 86_400),
                source: .fixture,
                updatedAt: now)
        case .loading:
            return UsageSnapshot.loading(updatedAt: now)
        case .runwaySafe:
            return UsageSnapshot(
                sessionPercentRemaining: 82,
                weeklyPercentRemaining: 79,
                sessionResetAt: now.addingTimeInterval(3 * 3_600),
                weeklyResetAt: now.addingTimeInterval(4 * 86_400),
                source: .fixture,
                updatedAt: now)
        case .missingReset:
            return UsageSnapshot(
                sessionPercentRemaining: nil,
                weeklyPercentRemaining: 61,
                sessionResetAt: nil,
                weeklyResetAt: nil,
                source: .fixture,
                updatedAt: now)
        case .stale, .refreshingCache:
            return base.markedStale(
                errorMessage: "Codex refresh is temporarily unavailable.",
                updatedAt: now.addingTimeInterval(-600))
        case .unavailable:
            return UsageSnapshot.error("No complete Codex usage window is available.", updatedAt: now)
        case .error:
            return UsageSnapshot.error("Codex refresh failed. No complete usage window is available.", updatedAt: now)
        case .authBlocked:
            return base.markedStale(errorMessage: "Codex authorization is required before usage can be checked.", updatedAt: now.addingTimeInterval(-600))
        case .rateLimited:
            return base.markedStale(errorMessage: "Codex usage is rate limited; retry in 60s.", updatedAt: now.addingTimeInterval(-120))
        case .extraWindow, .tall:
            return UsageSnapshot(
                sessionPercentRemaining: 63,
                weeklyPercentRemaining: 39,
                sessionResetAt: now.addingTimeInterval(8_400),
                weeklyResetAt: now.addingTimeInterval(277_200),
                extraWindows: [
                    UsageNamedWindow(
                        id: "spark-session",
                        title: "Codex Spark 5-hour",
                        window: UsageWindow(
                            usedPercent: 28,
                            resetAt: now.addingTimeInterval(10_800),
                            windowSeconds: 18_000)),
                    UsageNamedWindow(
                        id: "spark-weekly",
                        title: "Codex Spark Weekly",
                        window: UsageWindow(
                            usedPercent: 46,
                            resetAt: now.addingTimeInterval(345_600),
                            windowSeconds: 604_800)),
                ],
                source: .fixture,
                updatedAt: now)
        default:
            return base
        }
    }

    private static func analytics(
        variant: VisualQAVariant,
        now: Date) -> LocalUsageAnalyticsSnapshot
    {
        if variant == .analyticsUnavailable {
            return .unavailable(message: "No local Codex logs found.", updatedAt: now)
        }
        let calendar = Calendar(identifier: .gregorian)
        let bucketCount = variant == .baselineInsufficient ? 3 : 14
        let buckets = (0..<bucketCount).map { index -> LocalUsageDailyBucket in
            let date = calendar.date(byAdding: .day, value: -(bucketCount - 1 - index), to: now) ?? now
            let tokens = 15_000 + ((index % 6) * 4_200)
            return LocalUsageDailyBucket(
                date: LocalUsageLogScanner.dayFormatter.string(from: date),
                totalTokens: tokens,
                costUSD: Double(tokens) * 0.000004,
                requestCount: 2 + (index % 5))
        }
        return LocalUsageAnalyticsSnapshot(
            todayCostUSD: buckets.last?.costUSD,
            todayTokens: buckets.last?.totalTokens,
            last30DaysCostUSD: buckets.compactMap(\.costUSD).reduce(0, +),
            last30DaysTokens: buckets.reduce(0) { $0 + $1.totalTokens },
            latestTokens: 18_420,
            topModel: "gpt-5.4-codex",
            dailyHistory: buckets,
            updatedAt: now,
            sourceLabel: "Synthetic local logs",
            isCostPartial: variant == .analyticsPartial,
            recentWork: [
                RecentCodexWork(observedAt: now.addingTimeInterval(-8 * 60), model: "gpt-5.4-codex", tokenActivity: 18_420, confidence: "Local exact"),
                RecentCodexWork(observedAt: now.addingTimeInterval(-36 * 60), model: "gpt-5.4-codex", tokenActivity: 9_340, confidence: "Local exact"),
                RecentCodexWork(observedAt: now.addingTimeInterval(-2 * 3_600), model: "gpt-5.3-codex", tokenActivity: 4_120, confidence: "Partial"),
            ])
    }
}

private struct VisualQABackdrop: View {
    let variant: VisualQAVariant

    var body: some View {
        ZStack {
            self.baseColor
            if self.variant == .backdropColorful {
                HStack(spacing: 0) {
                    Color(nsColor: .systemIndigo).opacity(0.78)
                    Color(nsColor: .systemPink).opacity(0.62)
                    Color(nsColor: .systemOrange).opacity(0.70)
                }
            }
            VStack {
                HStack {
                    Text("CONTROLLED MATERIAL BACKDROP")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(self.variant == .backdropLight ? Color.black.opacity(0.48) : Color.white.opacity(0.48))
                    Spacer()
                }
                Spacer()
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var baseColor: Color {
        switch self.variant {
        case .backdropLight: Color(nsColor: .white)
        case .backdropColorful: Color(nsColor: .systemIndigo)
        default: Color(nsColor: NSColor(calibratedWhite: 0.055, alpha: 1))
        }
    }
}

private struct VisualMenuBarMock: View {
    let presentation: UsageDisplayFormatter.MenuBarPresentation

    var body: some View {
        VStack(spacing: 0) {
            if self.presentation.rows.count > 1 {
                HStack(spacing: 2) {
                    AppBrandIconView(size: 9)
                    Text(self.presentation.rows[0].value)
                }
                HStack(spacing: 2) {
                    Text(self.presentation.rows[1].marker ?? "W")
                        .font(.system(size: 8.5, weight: .bold))
                    Text(self.presentation.rows[1].value)
                }
            } else if let row = self.presentation.rows.first {
                if let resetText = row.resetText {
                    VStack(spacing: 0) {
                        HStack(spacing: 2) {
                            AppBrandIconView(size: 11)
                            Text(row.value)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Text(resetText)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                } else {
                    HStack(spacing: 2) {
                        AppBrandIconView(size: 12)
                        Text(row.value)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                }
            }
        }
        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .frame(width: StatusItemController.statusItemWidth, height: 22)
        .background(Color.black)
        .accessibilityLabel(self.presentation.accessibilityText)
    }
}
