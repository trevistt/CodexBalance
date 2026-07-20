import AppKit
import CodexBalanceCore
import SwiftUI

@MainActor
final class DashboardPinState: ObservableObject {
    @Published var isPinned: Bool {
        didSet { self.defaults.set(self.isPinned, forKey: Self.key) }
    }

    private let defaults: UserDefaults
    private static let key = "CodexBalance.dashboardPinned.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPinned = defaults.bool(forKey: Self.key)
    }

    func toggle() {
        self.isPinned.toggle()
    }
}

@MainActor
final class DashboardRefreshCoordinator: ObservableObject {
    @Published private(set) var feedback: String?
    private var feedbackGeneration = 0

    func perform(
        scheduler: RefreshScheduler,
        analyticsScheduler: LocalUsageAnalyticsScheduler,
        source: String)
    {
        ShortcutDiagnosticTrace.record(
            "refresh.coordinator.invoked",
            fields: [
                "presence": scheduler.presence.rawValue,
                "source": source,
            ])
        let accepted = scheduler.refreshNow()
        ShortcutDiagnosticTrace.record(
            "refresh.coordinator.scheduler.result",
            fields: [
                "accepted": accepted ? "true" : "false",
                "presence": scheduler.presence.rawValue,
                "source": source,
            ])
        self.feedbackGeneration += 1
        let generation = self.feedbackGeneration
        guard accepted else {
            let message = scheduler.presence.pauseReason
                .map { "Refresh unavailable. \($0)." }
                ?? "Refresh is already in progress."
            self.feedback = message
            ShortcutDiagnosticTrace.record(
                "feedback.transition",
                fields: [
                    "category": scheduler.presence.pauseReason == nil ? "busy" : "paused",
                    "source": source,
                    "state": "generated",
                ])
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.feedbackGeneration == generation else { return }
                self.feedback = nil
                ShortcutDiagnosticTrace.record(
                    "feedback.transition",
                    fields: [
                        "source": source,
                        "state": "cleared",
                    ])
            }
            return
        }
        self.feedback = nil
        ShortcutDiagnosticTrace.record(
            "feedback.transition",
            fields: [
                "source": source,
                "state": "refreshing",
            ])
        analyticsScheduler.refreshNow()
    }
}

/// Composition root for the dashboard. Store ownership, timer-driven display
/// updates and callbacks stay here; child sections receive presentation values.
struct HoverPanelView: View {
    static let panelWidth: CGFloat = 376
    static let naturalHeight: CGFloat = 820
    static let minimumHeight: CGFloat = 560

    static func preferredHeight(
        snapshot: UsageSnapshot,
        analytics: LocalUsageAnalyticsSnapshot,
        maxHeight: CGFloat) -> CGFloat
    {
        let hasCompactContent = UsageQuotaWindowPresentationResolver.resolve(snapshot: snapshot).rows.count <= 1
            && !analytics.hasAnyData
            && snapshot.extraWindows.isEmpty
        let target = hasCompactContent ? 700 : Self.naturalHeight
        return min(target, max(360, maxHeight))
    }

    @ObservedObject var usageStore: UsageStore
    @ObservedObject var scheduler: RefreshScheduler
    @ObservedObject var analyticsStore: LocalUsageAnalyticsStore
    @ObservedObject var analyticsScheduler: LocalUsageAnalyticsScheduler
    @ObservedObject var pinState: DashboardPinState
    @ObservedObject var refreshCoordinator: DashboardRefreshCoordinator

    let maxHeight: CGFloat
    let displayAccessibility: DashboardDisplayAccessibility
    let onQuit: () -> Void

    @State private var detailsExpanded: Bool
    @State private var copiedDiagnostics = false
    @State private var now = Date()
    @State private var activityRangeDays = 14

    init(
        usageStore: UsageStore,
        scheduler: RefreshScheduler,
        analyticsStore: LocalUsageAnalyticsStore,
        analyticsScheduler: LocalUsageAnalyticsScheduler,
        pinState: DashboardPinState,
        refreshCoordinator: DashboardRefreshCoordinator = DashboardRefreshCoordinator(),
        maxHeight: CGFloat,
        displayAccessibility: DashboardDisplayAccessibility = .system,
        initialDetailsExpanded: Bool = false,
        onQuit: @escaping () -> Void)
    {
        self.usageStore = usageStore
        self.scheduler = scheduler
        self.analyticsStore = analyticsStore
        self.analyticsScheduler = analyticsScheduler
        self.pinState = pinState
        self.refreshCoordinator = refreshCoordinator
        self.maxHeight = maxHeight
        self.displayAccessibility = displayAccessibility
        self._detailsExpanded = State(initialValue: initialDetailsExpanded)
        self.onQuit = onQuit
    }

    var body: some View {
        let presentation = self.presentation
        DashboardMaterialSurface(accessibility: self.displayAccessibility) {
            VStack(spacing: 0) {
                DashboardHeaderView(presentation: presentation)
                Divider().overlay(DashboardDesignTokens.divider(self.displayAccessibility))
                ScrollView {
                    VStack(spacing: DashboardDesignTokens.sectionSpacing) {
                        DashboardRunwayHeroView(presentation: presentation, now: self.now)
                        DashboardQuotaSectionView(presentation: presentation, now: self.now)
                        DashboardObservationSectionView(
                            presentation: presentation,
                            lastQuotaChangedAt: self.usageStore.lastQuotaChangedAt,
                            now: self.now)
                        DashboardAnalyticsSectionView(
                            snapshot: self.analyticsStore.snapshot,
                            now: self.now,
                            rangeDays: self.$activityRangeDays)
                        DashboardRecentWorkSectionView(snapshot: self.analyticsStore.snapshot, now: self.now)
                        DashboardDetailsSectionView(
                            state: self.diagnosticsState,
                            analytics: self.analyticsStore.snapshot,
                            isExpanded: self.$detailsExpanded,
                            copied: self.$copiedDiagnostics,
                            onCopy: self.copyDiagnostics)
                    }
                    .padding(.horizontal, DashboardDesignTokens.horizontalInset)
                    .padding(.vertical, 16)
                }
                .defaultScrollAnchor(.top)
                .accessibilityIdentifier("codexbalance.dashboard.body-scroll")
                Divider().overlay(DashboardDesignTokens.divider(self.displayAccessibility))
                DashboardFooterView(
                    isRefreshing: self.usageStore.isRefreshing,
                    isPinned: self.pinState.isPinned,
                    mode: self.scheduler.mode,
                    footerStatus: self.footerStatus,
                    refreshFeedback: self.refreshCoordinator.feedback,
                    onRefresh: self.refresh,
                    onPin: self.pinState.toggle,
                    onSetMode: self.scheduler.setMode,
                    onQuit: self.onQuit)
            }
        }
        .frame(width: Self.panelWidth, height: self.clampedHeight)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .background(Color.clear)
        .foregroundStyle(DashboardDesignTokens.primaryText)
        .transaction { transaction in
            if self.displayAccessibility.reduceMotion {
                transaction.animation = nil
            }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            self.now = date
        }
    }

    private var presentation: DashboardPresentation {
        DashboardPresentation(
            snapshot: self.usageStore.snapshot,
            observation: self.usageStore.observationState,
            isRefreshing: self.usageStore.isRefreshing,
            now: self.now)
    }

    private var clampedHeight: CGFloat {
        Self.preferredHeight(
            snapshot: self.usageStore.snapshot,
            analytics: self.analyticsStore.snapshot,
            maxHeight: self.maxHeight)
    }

    private var footerStatus: String {
        if let feedback = self.refreshCoordinator.feedback { return feedback }
        if self.usageStore.isRefreshing || self.analyticsStore.isRefreshing {
            return "Refreshing quota and local analytics..."
        }
        return self.scheduler.countdownText(now: self.now)
    }

    private var diagnosticsState: UsageDiagnosticsState {
        UsageDiagnosticsFormatter.state(
            snapshot: self.usageStore.snapshot,
            storeLastSuccess: self.usageStore.lastSuccessfulRefreshAt,
            storeLastError: self.usageStore.lastErrorMessage,
            mode: self.scheduler.mode,
            presence: self.scheduler.presence,
            nextRefreshAt: self.scheduler.nextRefreshAt,
            analytics: self.analyticsStore.snapshot,
            analyticsLastSuccess: self.analyticsStore.lastSuccessfulRefreshAt,
            now: self.now)
    }

    private func refresh() {
        ShortcutDiagnosticTrace.record(
            "swiftui.refresh.invoked",
            fields: ["presence": self.scheduler.presence.rawValue])
        self.refreshCoordinator.perform(
            scheduler: self.scheduler,
            analyticsScheduler: self.analyticsScheduler,
            source: "swiftui")
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            UsageDiagnosticsFormatter.exportText(self.diagnosticsState),
            forType: .string)
        self.copiedDiagnostics = true
    }
}
