import AppKit
import CodexBalanceCore
import SwiftUI

@MainActor
final class NotchPillController {
    private let usageStore: UsageStore
    private let scheduler: RefreshScheduler
    private let analyticsStore: LocalUsageAnalyticsStore
    private let analyticsScheduler: LocalUsageAnalyticsScheduler
    private let pinState: DashboardPinState
    private var pillWindow: NSPanel?
    private var detailWindow: NSPanel?

    init(
        usageStore: UsageStore,
        scheduler: RefreshScheduler,
        analyticsStore: LocalUsageAnalyticsStore,
        analyticsScheduler: LocalUsageAnalyticsScheduler,
        pinState: DashboardPinState)
    {
        self.usageStore = usageStore
        self.scheduler = scheduler
        self.analyticsStore = analyticsStore
        self.analyticsScheduler = analyticsScheduler
        self.pinState = pinState
    }

    func showIfAvailable() {
        guard let screen = NSScreen.main else { return }
        let size = NSSize(width: 118, height: 30)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - 4)
        let panel = self.pillWindow ?? self.makePillWindow()
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func close() {
        self.pillWindow?.close()
        self.detailWindow?.close()
        self.pillWindow = nil
        self.detailWindow = nil
    }

    private func makePillWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchPillView(
            usageStore: self.usageStore,
            action: { [weak self] in self?.toggleDetail() }))
        self.pillWindow = panel
        return panel
    }

    private func toggleDetail() {
        if self.detailWindow?.isVisible == true {
            self.detailWindow?.orderOut(nil)
            self.scheduler.setDashboardVisible(false)
            return
        }
        guard let pillWindow, let screen = pillWindow.screen ?? NSScreen.main else { return }
        let height = HoverPanelView.preferredHeight(
            snapshot: self.usageStore.snapshot,
            analytics: self.analyticsStore.snapshot,
            maxHeight: max(360, screen.visibleFrame.height - 24))
        let detail = self.detailWindow ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HoverPanelView.panelWidth, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        if self.detailWindow == nil {
            detail.level = .statusBar
            detail.isFloatingPanel = true
            detail.backgroundColor = .clear
            detail.isOpaque = false
            detail.hasShadow = true
            detail.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            detail.contentViewController = NSHostingController(rootView: HoverPanelView(
                usageStore: self.usageStore,
                scheduler: self.scheduler,
                analyticsStore: self.analyticsStore,
                analyticsScheduler: self.analyticsScheduler,
                pinState: self.pinState,
                maxHeight: height,
                onQuit: { NSApp.terminate(nil) }))
            self.detailWindow = detail
        }
        let x = min(
            max(pillWindow.frame.midX - HoverPanelView.panelWidth / 2, screen.visibleFrame.minX + 8),
            screen.visibleFrame.maxX - HoverPanelView.panelWidth - 8)
        let y = max(screen.visibleFrame.minY + 8, pillWindow.frame.minY - height - 6)
        detail.setFrame(NSRect(x: x, y: y, width: HoverPanelView.panelWidth, height: height), display: true)
        detail.makeKeyAndOrderFront(nil)
        self.scheduler.setDashboardVisible(true)
    }
}

private struct NotchPillView: View {
    @ObservedObject var usageStore: UsageStore
    let action: () -> Void

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 7) {
                AppBrandIconView(size: 14)
                Text(UsageDisplayFormatter.menuBarCompactText(
                    snapshot: self.usageStore.snapshot,
                    isRefreshing: self.usageStore.isRefreshing))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.9))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Open CodexBalance Codex dashboard")
    }
}
