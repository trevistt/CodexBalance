import AppKit
import CodexBalanceCore
import SwiftUI

@MainActor
enum UISmokeCheck {
    static func run() -> Bool {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
            assertions += 1
            guard condition() else {
                fputs("SMOKE_CHECK_FAIL: \(message)\n", stderr)
                return false
            }
            return true
        }

        let now = Date(timeIntervalSince1970: 1_784_188_800)
        let fixtureUUID = "5f7ecdc3-03dd-4a1e-b7fc-98237b278ba8"
        guard expect(
            UIQAFixtureLaunch.parse(arguments: ["CodexBalance"]) == .production,
            "ordinary launch remains production"),
              expect(
                UIQAFixtureLaunch.parse(arguments: ["CodexBalance", "--ui-qa-state=success"]) == .invalid,
                "fixture state without nonce fails closed"),
              expect(
                UIQAFixtureLaunch.parse(arguments: ["CodexBalance", "--ui-qa-fixture=invalid", "--ui-qa-state=success"]) == .invalid,
                "invalid fixture nonce fails closed"),
              expect(
                UIQAFixtureLaunch.parse(arguments: ["CodexBalance", "--ui-qa-fixture=\(fixtureUUID)"]) == .invalid,
                "fixture nonce without state fails closed"),
              expect(
                UIQAFixtureLaunch.parse(arguments: ["CodexBalance", "--ui-qa-fixture=\(fixtureUUID)", "--ui-qa-state=success"])
                    == .fixture(nonce: fixtureUUID, state: "success"),
                "valid fixture arguments are accepted atomically")
        else { return false }

        let healthy = UsageSnapshot(
            sessionPercentRemaining: 35,
            weeklyPercentRemaining: 95,
            sessionResetAt: now.addingTimeInterval(7_200),
            weeklyResetAt: now.addingTimeInterval(4 * 86_400),
            source: .fixture,
            updatedAt: now)
        let presentation = UsageDisplayFormatter.menuBarPresentation(snapshot: healthy, now: now)
        guard expect(presentation.rows.count == 2, "healthy display has Session and Weekly rows"),
              expect(presentation.rows[0].value == "35%", "Session value"),
              expect(presentation.rows[1].value == "95%", "Weekly value"),
              expect(presentation.rows[1].marker == "W", "Weekly role marker"),
              expect(presentation.rows[0].resetText == "2h 0m", "Session reset countdown"),
              expect(presentation.accessibilityText.contains("OpenAI Codex Session"), "AX provider and role"),
              expect(presentation.accessibilityText.contains("Can keep working"), "AX includes decision meaning")
        else { return false }

        let dashboardPresentation = DashboardPresentation(
            snapshot: healthy,
            observation: UsageObservationState(),
            isRefreshing: false,
            now: now)
        guard expect(dashboardPresentation.quotaRows.map(\.row.role) == [.session, .weekly], "dashboard preserves Session then Weekly identity"),
              expect(dashboardPresentation.quotaRows.first?.isLimiting == true, "dashboard identifies the limiting row without reordering"),
              expect(dashboardPresentation.statusSlot.tone == .safe, "dashboard derives a live status slot without provider mutation"),
              expect(dashboardPresentation.statusSlot.title == "Live quota", "dashboard has one truthful live status slot"),
              expect(dashboardPresentation.runway?.remainingText == "35%", "runway uses the limiting Session value"),
              expect(dashboardPresentation.runway?.windowLabel == "Session", "runway retains window identity"),
              expect(dashboardPresentation.observationDetail.contains("Changes appear"), "dashboard does not invent a change before two checks")
        else { return false }

        let calendar = Calendar(identifier: .gregorian)
        let history = (0...7).map { index -> LocalUsageDailyBucket in
            let date = calendar.date(byAdding: .day, value: -(7 - index), to: now) ?? now
            return LocalUsageDailyBucket(
                date: LocalUsageLogScanner.dayFormatter.string(from: date),
                totalTokens: (index + 1) * 1_000,
                costUSD: nil,
                requestCount: 1)
        }
        let comparison = TodayVsNormalPresentation(
            snapshot: LocalUsageAnalyticsSnapshot(
                todayCostUSD: nil,
                todayTokens: 8_000,
                last30DaysCostUSD: nil,
                last30DaysTokens: 36_000,
                latestTokens: 8_000,
                topModel: "gpt-5.4-codex",
                dailyHistory: history,
                updatedAt: now),
            now: now)
        guard expect(comparison.isAvailable, "Today-versus-normal builds after at least three prior days"),
              expect(comparison.baselineTokens == 4_000, "Today-versus-normal uses the median of seven prior days"),
              expect(comparison.deltaText == "100% above normal", "Today-versus-normal reports a truthful delta")
        else { return false }

        let insufficient = TodayVsNormalPresentation(
            snapshot: LocalUsageAnalyticsSnapshot(
                todayCostUSD: nil,
                todayTokens: 3_000,
                last30DaysCostUSD: nil,
                last30DaysTokens: 6_000,
                latestTokens: 3_000,
                topModel: nil,
                dailyHistory: Array(history.suffix(3)),
                updatedAt: now),
            now: now)
        guard expect(!insufficient.isAvailable, "two prior days do not invent a baseline"),
              expect(insufficient.deltaText.contains("2/3 days"), "insufficient baseline explains progress")
        else { return false }

        let partialComparison = TodayVsNormalPresentation(
            snapshot: LocalUsageAnalyticsSnapshot(
                todayCostUSD: 0.01,
                todayTokens: 8_000,
                last30DaysCostUSD: 0.10,
                last30DaysTokens: 36_000,
                latestTokens: 8_000,
                topModel: "gpt-5.4-codex",
                dailyHistory: history,
                updatedAt: now,
                isCostPartial: true),
            now: now)
        guard expect(partialComparison.confidenceText == "Estimated - Partial", "partial local analytics is not labelled exact")
        else { return false }

        let loadingDashboardPresentation = DashboardPresentation(
            snapshot: .loading(updatedAt: now),
            observation: UsageObservationState(),
            isRefreshing: true,
            now: now)
        guard expect(loadingDashboardPresentation.statusSlot.tone == .neutral, "loading presentation is neutral"),
              expect(loadingDashboardPresentation.statusSlot.title == "Checking Codex quota", "loading presentation has truthful title")
        else { return false }

        let authBlockedPresentation = DashboardPresentation(
            snapshot: healthy.markedStale(
                errorMessage: "Codex authorization is required before usage can be checked.",
                updatedAt: now.addingTimeInterval(-600)),
            observation: UsageObservationState(),
            isRefreshing: false,
            now: now)
        guard expect(authBlockedPresentation.statusSlot.title == "Login needed", "authorization has an actionable state"),
              expect(authBlockedPresentation.statusSlot.detail.contains("Open Codex"), "authorization state gives the next action")
        else { return false }

        let noResetPresentation = DashboardPresentation(
            snapshot: UsageSnapshot(
                sessionPercentRemaining: nil,
                weeklyPercentRemaining: 61,
                sessionResetAt: nil,
                weeklyResetAt: nil,
                source: .fixture,
                updatedAt: now),
            observation: UsageObservationState(),
            isRefreshing: false,
            now: now)
        guard expect(noResetPresentation.runway?.resetAt == nil, "missing reset remains unavailable in runway truth"),
              expect(noResetPresentation.runway?.projectionText == "Projection unavailable", "missing reset does not invent a projection")
        else { return false }

        let weeklyOnly = UsageSnapshot(
            sessionPercentRemaining: nil,
            weeklyPercentRemaining: 43,
            sessionResetAt: nil,
            weeklyResetAt: now.addingTimeInterval(4 * 86_400),
            source: .fixture,
            updatedAt: now)
        let weeklyPresentation = UsageDisplayFormatter.menuBarPresentation(snapshot: weeklyOnly, now: now)
        guard expect(weeklyPresentation.rows.count == 1, "weekly-only does not synthesize Session"),
              expect(weeklyPresentation.rows[0].windowRole == .weekly, "weekly-only role"),
              expect(weeklyPresentation.rows[0].marker == nil, "weekly-only needs no duplicate marker"),
              expect(weeklyPresentation.rows[0].resetText == "4d 0h", "weekly-only reset countdown")
        else { return false }

        let stale = healthy.markedStale(
            errorMessage: "Temporary refresh failure.",
            updatedAt: now.addingTimeInterval(-600))
        let stalePresentation = UsageDisplayFormatter.menuBarPresentation(snapshot: stale, now: now)
        guard expect(stalePresentation.rows.allSatisfy { $0.value.hasSuffix("!") }, "stale marker"),
              expect(stalePresentation.accessibilityText.contains("cached stale"), "stale AX truth")
        else { return false }

        let hardError = UsageSnapshot.error("Provider unavailable.", updatedAt: now)
        let errorPresentation = UsageDisplayFormatter.menuBarPresentation(snapshot: hardError, now: now)
        guard expect(errorPresentation.rows.first?.value == "--", "hard error is compact unavailable"),
              expect(!errorPresentation.accessibilityText.contains("percent remaining, fresh"), "error not presented live")
        else { return false }

        let loading = UsageDisplayFormatter.menuBarPresentation(
            snapshot: hardError,
            isRefreshing: true,
            now: now)
        guard expect(loading.isRefreshing, "loading state"),
              expect(loading.accessibilityText.contains("loading"), "loading AX")
        else { return false }

        let frame = StatusPanelPositioner.origin(
            statusItemFrame: NSRect(x: 1_330, y: 880, width: 42, height: 22),
            panelSize: NSSize(width: HoverPanelView.panelWidth, height: 820),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 878))
        guard expect(frame.x >= 8, "panel left containment"),
              expect(frame.x + HoverPanelView.panelWidth <= 1_432, "panel right containment"),
              expect(frame.y >= 8, "panel bottom containment"),
              expect(frame.y + 820 <= 878, "panel top containment"),
              expect(HoverPanelView.panelWidth == 376, "dashboard uses the planned 376pt width"),
              expect(AppBrandIcon.isAvailable, "Codex Balance brand mark available")
        else { return false }

        let screens = [
            (frame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
             visibleFrame: NSRect(x: -1_920, y: 0, width: 1_920, height: 1_056)),
            (frame: NSRect(x: 0, y: 0, width: 1_440, height: 900),
             visibleFrame: NSRect(x: 0, y: 0, width: 1_440, height: 876)),
            (frame: NSRect(x: 0, y: 900, width: 1_440, height: 900),
             visibleFrame: NSRect(x: 0, y: 900, width: 1_440, height: 876)),
        ]
        let leftVisible = StatusPanelPositioner.visibleFrame(
            containing: NSRect(x: -80, y: 1_056, width: 46, height: 24),
            screens: screens,
            fallback: nil)
        let upperVisible = StatusPanelPositioner.visibleFrame(
            containing: NSRect(x: 700, y: 1_776, width: 46, height: 24),
            screens: screens,
            fallback: nil)
        guard expect(leftVisible == screens[0].visibleFrame, "negative-x display selection"),
              expect(upperVisible == screens[2].visibleFrame, "vertical display selection")
        else { return false }

        let nonce = UUID().uuidString
        let usageStore = UsageStore(
            provider: FixtureCodexUsageProvider(now: { now }),
            cache: UsageSnapshotCache(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-balance-smoke-\(nonce)-usage.json")))
        let analyticsStore = LocalUsageAnalyticsStore(
            provider: FixtureLocalUsageAnalyticsProvider(now: { now }),
            cache: LocalUsageAnalyticsCache(url: FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-balance-smoke-\(nonce)-analytics.json")))
        usageStore.replaceSnapshotForTesting(healthy)
        analyticsStore.replaceSnapshotForTesting(LocalUsageAnalyticsSnapshot(
            todayCostUSD: 0.12,
            todayTokens: 20_000,
            last30DaysCostUSD: 1.8,
            last30DaysTokens: 320_000,
            latestTokens: 8_000,
            topModel: "gpt-5.4-codex",
            dailyHistory: [],
            updatedAt: now,
            sourceLabel: "Synthetic local logs"))
        let scheduler = RefreshScheduler(
            store: usageStore,
            defaults: UserDefaults(suiteName: "CodexBalance.Smoke.\(nonce)")!,
            now: { now },
            jitterUnit: { 0.5 })
        let analyticsScheduler = LocalUsageAnalyticsScheduler(store: analyticsStore)
        let refreshCoordinator = DashboardRefreshCoordinator()
        scheduler.updatePresence(.idle)
        refreshCoordinator.perform(
            scheduler: scheduler,
            analyticsScheduler: analyticsScheduler,
            source: "smoke")
        guard expect(
            refreshCoordinator.feedback?.contains("Refresh unavailable") == true,
            "shared refresh coordinator acknowledges an idle scheduler rejection")
        else { return false }
        scheduler.updatePresence(.active)
        let pinState = DashboardPinState(defaults: UserDefaults(suiteName: "CodexBalance.Smoke.Pin.\(nonce)")!)
        let controller = StatusItemController(
            usageStore: usageStore,
            scheduler: scheduler,
            analyticsStore: analyticsStore,
            analyticsScheduler: analyticsScheduler,
            pinState: pinState,
            now: { now })
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard expect(controller.statusItemWidthForTesting() == 46, "status width is the readable 46pt target"),
              expect(controller.menuBarValuesForTesting() == ["35%", "W 95%"], "custom meter mirrors snapshot"),
              expect(controller.menuBarHasBrandIconForTesting(), "meter uses packaged Codex Balance mark")
        else {
            controller.invalidate()
            return false
        }

        usageStore.replaceSnapshotForTesting(UsageSnapshot(
            sessionPercentRemaining: 9,
            weeklyPercentRemaining: 100,
            sessionResetAt: now.addingTimeInterval(1_800),
            weeklyResetAt: now.addingTimeInterval(5 * 86_400),
            source: .fixture,
            updatedAt: now))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard expect(controller.menuBarValuesForTesting() == ["9%", "W 100%"], "meter invalidates after snapshot update")
        else {
            controller.invalidate()
            return false
        }

        usageStore.replaceSnapshotForTesting(weeklyOnly)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard expect(controller.menuBarValuesForTesting() == ["43%", "4d 0h"], "weekly-only meter shows reset countdown"),
              expect(controller.menuBarTopFontSizeForTesting() >= 13, "weekly-only percentage uses large type")
        else {
            controller.invalidate()
            return false
        }

        let root = HoverPanelView(
            usageStore: usageStore,
            scheduler: scheduler,
            analyticsStore: analyticsStore,
            analyticsScheduler: analyticsScheduler,
            pinState: pinState,
            maxHeight: HoverPanelView.naturalHeight,
            displayAccessibility: .standardFixture,
            onQuit: {})
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: HoverPanelView.panelWidth, height: HoverPanelView.naturalHeight)
        hosting.layoutSubtreeIfNeeded()
        guard expect(hosting.fittingSize.width > 0, "dashboard root builds"),
              expect(hosting.fittingSize.height > 0, "dashboard content has height"),
              expect(Self.containsVisualEffect(in: hosting), "dashboard hosts an AppKit visual effect material")
        else {
            controller.invalidate()
            return false
        }

        let diagnostics = UsageDiagnosticsFormatter.exportText(
            UsageDiagnosticsFormatter.state(
                snapshot: healthy,
                storeLastSuccess: now,
                storeLastError: "Authorization: Bearer synthetic-secret",
                mode: .automatic,
                presence: .active,
                nextRefreshAt: now.addingTimeInterval(60),
                analytics: analyticsStore.snapshot,
                analyticsLastSuccess: now,
                now: now))
        guard expect(!diagnostics.contains("synthetic-secret"), "diagnostics strips authorization value"),
              expect(!diagnostics.contains("/Users/"), "diagnostics contains no full user path"),
              expect(diagnostics.contains("Provider: OpenAI Codex"), "diagnostics identifies provider")
        else {
            controller.invalidate()
            return false
        }

        controller.invalidate()
        print("SMOKE_CHECK_PASS assertions=\(assertions) status_width=\(Int(StatusItemController.statusItemWidth))")
        return true
    }

    private static func containsVisualEffect(in view: NSView) -> Bool {
        if view is NSVisualEffectView { return true }
        return view.subviews.contains { self.containsVisualEffect(in: $0) }
    }
}
