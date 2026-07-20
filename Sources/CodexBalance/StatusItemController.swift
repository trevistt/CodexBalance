import AppKit
import Combine
import CodexBalanceCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    static let statusItemWidth: CGFloat = 46

    private let usageStore: UsageStore
    private let scheduler: RefreshScheduler
    private let analyticsStore: LocalUsageAnalyticsStore
    private let analyticsScheduler: LocalUsageAnalyticsScheduler
    private let pinState: DashboardPinState
    private let refreshCoordinator = DashboardRefreshCoordinator()
    private let now: () -> Date
    private let maxPanelHeightOverride: CGFloat?
    private let statusItem: NSStatusItem
    private let meterView = MenuBarMeterView(frame: NSRect(
        x: 0,
        y: 0,
        width: StatusItemController.statusItemWidth,
        height: NSStatusBar.system.thickness))
    private let hoverView = StatusHoverView()
    private var panel: StatusPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var dismissalTimer: Timer?
    private var escapeMonitor: Any?
    private var globalShortcutMonitor: Any?
    private var lastInsideAt = Date.distantPast
    private var panelIsInteractive = false
    private var eventStatusItemFrame: NSRect?

    init(
        usageStore: UsageStore,
        scheduler: RefreshScheduler,
        analyticsStore: LocalUsageAnalyticsStore,
        analyticsScheduler: LocalUsageAnalyticsScheduler,
        pinState: DashboardPinState = DashboardPinState(),
        maxPanelHeightOverride: CGFloat? = nil,
        now: @escaping () -> Date = Date.init)
    {
        self.usageStore = usageStore
        self.scheduler = scheduler
        self.analyticsStore = analyticsStore
        self.analyticsScheduler = analyticsScheduler
        self.pinState = pinState
        self.maxPanelHeightOverride = maxPanelHeightOverride
        self.now = now
        self.statusItem = NSStatusBar.system.statusItem(withLength: Self.statusItemWidth)
        super.init()
        self.configureStatusItem()
        self.observeState()
        self.updateMeter()
        self.startDismissalMonitor()
    }

    func invalidate() {
        self.dismissalTimer?.invalidate()
        self.dismissalTimer = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if let globalShortcutMonitor {
            NSEvent.removeMonitor(globalShortcutMonitor)
            self.globalShortcutMonitor = nil
        }
        self.panel?.orderOut(nil)
        self.panel = nil
        NSStatusBar.system.removeStatusItem(self.statusItem)
    }

    func menuBarValuesForTesting() -> [String] {
        self.meterView.valuesForTesting()
    }

    func menuBarTopFontSizeForTesting() -> CGFloat {
        self.meterView.topFontSizeForTesting()
    }

    func menuBarHasBrandIconForTesting() -> Bool {
        self.meterView.hasBrandIconForTesting()
    }

    func statusItemWidthForTesting() -> CGFloat {
        self.statusItem.length
    }

    func showPanelForTesting(interactive: Bool = true) {
        self.showPanel(interactive: interactive)
    }

    func hidePanelForTesting() {
        self.hidePanel()
    }

    func panelFrameForTesting() -> NSRect? {
        self.panel?.frame
    }

    func statusItemFrameForTesting() -> NSRect? {
        self.statusItemScreenFrame()
    }

    private func configureStatusItem() {
        guard let button = self.statusItem.button else { return }
        button.title = ""
        button.image = nil
        button.target = self
        button.action = #selector(self.statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityIdentifier("codexbalance.status-item")
        button.setAccessibilityRole(.button)

        self.meterView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(self.meterView)
        NSLayoutConstraint.activate([
            self.meterView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            self.meterView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            self.meterView.topAnchor.constraint(equalTo: button.topAnchor),
            self.meterView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])

        self.hoverView.translatesAutoresizingMaskIntoConstraints = false
        self.hoverView.onEnter = { [weak self] frame in
            self?.recordEventStatusItemFrame(frame)
            self?.showPanel(interactive: false)
        }
        self.hoverView.onClick = { [weak self] frame in
            self?.recordEventStatusItemFrame(frame)
            self?.statusItemClicked()
        }
        self.hoverView.onMove = { [weak self] frame in
            guard let self else { return }
            self.recordEventStatusItemFrame(frame)
            self.lastInsideAt = Date()
            if self.panel?.isVisible != true {
                self.showPanel(interactive: false)
            }
        }
        button.addSubview(self.hoverView)
        NSLayoutConstraint.activate([
            self.hoverView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            self.hoverView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            self.hoverView.topAnchor.constraint(equalTo: button.topAnchor),
            self.hoverView.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
    }

    private func observeState() {
        self.usageStore.$snapshot
            .combineLatest(self.usageStore.$isRefreshing)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.updateMeter()
                if let panel = self?.panel, panel.isVisible {
                    self?.updatePanelFrame(panel)
                }
            }
            .store(in: &self.cancellables)

        self.analyticsStore.$snapshot
            .combineLatest(self.analyticsStore.$isRefreshing)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                if let panel = self?.panel, panel.isVisible {
                    self?.updatePanelFrame(panel)
                }
            }
            .store(in: &self.cancellables)

        self.pinState.$isPinned
            .dropFirst()
            .sink { [weak self] pinned in
                self?.startDismissalMonitor(interval: pinned ? 1.0 : 0.12)
                if !pinned {
                    self?.lastInsideAt = Date()
                }
            }
            .store(in: &self.cancellables)
    }

    private func updateMeter() {
        let presentation = UsageDisplayFormatter.menuBarPresentation(
            snapshot: self.usageStore.snapshot,
            isRefreshing: self.usageStore.isRefreshing,
            now: self.now())
        self.meterView.update(presentation: presentation)
        guard let button = self.statusItem.button else { return }
        button.toolTip = presentation.accessibilityText
        button.setAccessibilityLabel(presentation.accessibilityText)
        button.setAccessibilityHelp("Open the CodexBalance Codex dashboard")
        button.needsDisplay = true
        button.needsLayout = true
    }

    @objc private func statusItemClicked() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
        if self.panel?.isVisible == true,
           self.panelIsInteractive,
           !self.pinState.isPinned
        {
            self.hidePanel()
        } else {
            self.showPanel(interactive: true)
        }
    }

    private func showPanel(interactive: Bool) {
        let panel = self.ensurePanel()
        self.updatePanelFrame(panel)
        self.lastInsideAt = Date()
        self.scheduler.setDashboardVisible(true)
        if interactive {
            self.panelIsInteractive = true
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            if !panel.isVisible {
                self.panelIsInteractive = false
            }
            panel.orderFrontRegardless()
        }
    }

    private func hidePanel() {
        guard !self.pinState.isPinned else { return }
        self.panel?.orderOut(nil)
        self.panelIsInteractive = false
        self.scheduler.setDashboardVisible(false)
    }

    private func ensurePanel() -> StatusPanel {
        if let panel { return panel }
        let panel = StatusPanel(
            contentRect: NSRect(x: 0, y: 0, width: HoverPanelView.panelWidth, height: HoverPanelView.naturalHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.shouldRemainVisible = { [weak pinState = self.pinState] in
            pinState?.isPinned == true
        }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .utilityWindow
        panel.setAccessibilityIdentifier("codexbalance.dashboard.panel")

        let visibleHeight = self.visibleFrameForStatusItem()?.height ?? HoverPanelView.naturalHeight
        let root = HoverPanelView(
            usageStore: self.usageStore,
            scheduler: self.scheduler,
            analyticsStore: self.analyticsStore,
            analyticsScheduler: self.analyticsScheduler,
            pinState: self.pinState,
            refreshCoordinator: self.refreshCoordinator,
            maxHeight: self.panelMaximumHeight(visibleHeight: visibleHeight),
            onQuit: { NSApp.terminate(nil) })
        let hosting = NSHostingController(rootView: root)
        panel.contentViewController = hosting
        self.panel = panel

        self.escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self {
                ShortcutDiagnosticTrace.record(
                    "monitor.local.received",
                    panel: self.panel,
                    interactive: self.panelIsInteractive,
                    fields: [
                        "keyCode": String(event.keyCode),
                        "command": event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) ? "true" : "false",
                    ])
            }
            guard let self, self.handleDashboardShortcut(event) else { return event }
            return nil
        }
        // An accessory application can keep its panel key while macOS leaves
        // another app frontmost. Mirror the documented panel shortcuts only
        // while the user is actively interacting with this panel.
        self.globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                ShortcutDiagnosticTrace.record(
                    "monitor.global.received",
                    panel: self.panel,
                    interactive: self.panelIsInteractive,
                    fields: [
                        "keyCode": String(event.keyCode),
                        "command": event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) ? "true" : "false",
                    ])
                _ = self.handleDashboardShortcut(event)
            }
        }
        return panel
    }

    @discardableResult
    private func handleDashboardShortcut(_ event: NSEvent) -> Bool {
        ShortcutDiagnosticTrace.record(
            "shortcut.handler.invoked",
            panel: self.panel,
            interactive: self.panelIsInteractive,
            fields: ["keyCode": String(event.keyCode)])
        guard self.panel?.isVisible == true, self.panelIsInteractive else {
            ShortcutDiagnosticTrace.record(
                "shortcut.handler.rejected",
                panel: self.panel,
                interactive: self.panelIsInteractive,
                fields: ["reason": "panel_state"])
            return false
        }
        if event.keyCode == 53 {
            if self.pinState.isPinned { self.pinState.isPinned = false }
            self.hidePanel()
            return true
        }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        else { return false }
        if event.keyCode == 35 {
            self.pinState.toggle()
            return true
        }
        if event.keyCode == 15 {
            self.refreshCoordinator.perform(
                scheduler: self.scheduler,
                analyticsScheduler: self.analyticsScheduler,
                source: "shortcut")
            return true
        }
        return false
    }

    private func updatePanelFrame(_ panel: NSPanel) {
        guard let statusFrame = self.statusItemScreenFrame(),
              let visibleFrame = self.visibleFrameForStatusItem()
        else { return }
        let maxHeight = self.panelMaximumHeight(visibleHeight: visibleFrame.height)
        let height = HoverPanelView.preferredHeight(
            snapshot: self.usageStore.snapshot,
            analytics: self.analyticsStore.snapshot,
            maxHeight: maxHeight)
        let size = NSSize(width: HoverPanelView.panelWidth, height: height)
        let origin = StatusPanelPositioner.origin(
            statusItemFrame: statusFrame,
            panelSize: size,
            visibleFrame: visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func panelMaximumHeight(visibleHeight: CGFloat) -> CGFloat {
        let availableHeight = max(360, visibleHeight - 24)
        guard let maxPanelHeightOverride else { return availableHeight }
        return min(availableHeight, max(360, maxPanelHeightOverride))
    }

    private func startDismissalMonitor(interval: TimeInterval = 0.12) {
        self.dismissalTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateDismissal()
            }
        }
        timer.tolerance = min(0.2, interval * 0.2)
        self.dismissalTimer = timer
    }

    private func evaluateDismissal() {
        let point = NSEvent.mouseLocation
        // A pinned dashboard is an explicit persistence request. AppKit can
        // transiently order a status-level panel out during long accessory-app
        // runs; restore it rather than treating that as an auto-dismiss.
        if self.pinState.isPinned {
            if self.panel?.isVisible != true {
                self.showPanel(interactive: true)
            }
            return
        }
        let statusContains = self.statusItemScreenFrame()?.insetBy(dx: -4, dy: -4).contains(point) == true
        if statusContains {
            self.lastInsideAt = Date()
            if self.panel?.isVisible != true {
                self.showPanel(interactive: false)
            }
            return
        }

        guard let panel, panel.isVisible, !self.pinState.isPinned else { return }
        let panelContains = panel.frame.insetBy(dx: -6, dy: -6).contains(point)
        if panelContains {
            self.lastInsideAt = Date()
            return
        }
        if Date().timeIntervalSince(self.lastInsideAt) > 0.32 {
            self.hidePanel()
        }
    }

    private func statusItemScreenFrame() -> NSRect? {
        if let eventStatusItemFrame { return eventStatusItemFrame }
        guard let button = self.statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func recordEventStatusItemFrame(_ frame: NSRect?) {
        guard let frame, frame.width > 0, frame.height > 0 else { return }
        self.eventStatusItemFrame = frame
        if let panel, panel.isVisible {
            self.updatePanelFrame(panel)
        }
    }

    private func visibleFrameForStatusItem() -> NSRect? {
        guard let frame = self.statusItemScreenFrame() else { return NSScreen.main?.visibleFrame }
        return StatusPanelPositioner.visibleFrame(
            containing: frame,
            screens: NSScreen.screens.map { (frame: $0.frame, visibleFrame: $0.visibleFrame) },
            fallback: NSScreen.main?.visibleFrame)
    }
}

private final class StatusPanel: NSPanel {
    var shouldRemainVisible: () -> Bool = { false }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func orderOut(_ sender: Any?) {
        guard !self.shouldRemainVisible() else {
            self.orderFrontRegardless()
            return
        }
        super.orderOut(sender)
    }

    override func close() {
        guard !self.shouldRemainVisible() else {
            self.orderFrontRegardless()
            return
        }
        super.close()
    }
}

enum StatusPanelPositioner {
    static func visibleFrame(
        containing statusItemFrame: NSRect,
        screens: [(frame: NSRect, visibleFrame: NSRect)],
        fallback: NSRect?) -> NSRect?
    {
        let anchor = NSPoint(x: statusItemFrame.midX, y: statusItemFrame.midY)
        return screens.first(where: { $0.frame.contains(anchor) })?.visibleFrame ?? fallback
    }

    static func origin(
        statusItemFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect) -> NSPoint
    {
        let horizontalPadding: CGFloat = 8
        let preferredX = statusItemFrame.midX - panelSize.width / 2
        let x = min(
            max(preferredX, visibleFrame.minX + horizontalPadding),
            visibleFrame.maxX - panelSize.width - horizontalPadding)
        let preferredY = statusItemFrame.minY - panelSize.height - 6
        let y = min(
            max(preferredY, visibleFrame.minY + horizontalPadding),
            visibleFrame.maxY - panelSize.height)
        return NSPoint(x: x, y: y)
    }
}

private final class StatusHoverView: NSView {
    var onEnter: ((NSRect?) -> Void)?
    var onMove: ((NSRect?) -> Void)?
    var onClick: ((NSRect?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        if let tracking { self.removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(
            rect: self.bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil)
        self.addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        let frame = self.screenFrame(for: event)
        self.onEnter?(frame)
        self.onMove?(frame)
    }

    override func mouseMoved(with event: NSEvent) {
        self.onMove?(self.screenFrame(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        self.onClick?(self.screenFrame(for: event))
    }

    override func rightMouseUp(with event: NSEvent) {
        self.onClick?(self.screenFrame(for: event))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    private func screenFrame(for event: NSEvent) -> NSRect? {
        let localPoint = self.convert(event.locationInWindow, from: nil)
        let screenPoint = NSEvent.mouseLocation
        return NSRect(
            x: screenPoint.x - localPoint.x,
            y: screenPoint.y - localPoint.y,
            width: self.bounds.width,
            height: self.bounds.height)
    }
}

final class MenuBarMeterView: NSView {
    private let iconView = NSImageView()
    private let topLabel = NSTextField(labelWithString: "--")
    private let bottomMarker = NSTextField(labelWithString: "W")
    private let bottomLabel = NSTextField(labelWithString: "--")
    private var presentation = UsageDisplayFormatter.menuBarPresentation(
        snapshot: UsageSnapshot.error("Usage unavailable."))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        self.configure()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: StatusItemController.statusItemWidth, height: NSStatusBar.system.thickness)
    }

    func update(presentation: UsageDisplayFormatter.MenuBarPresentation) {
        self.presentation = presentation
        self.applyPresentation()
        self.topLabel.needsDisplay = true
        self.bottomLabel.needsDisplay = true
        self.bottomMarker.needsDisplay = true
        self.iconView.needsDisplay = true
        self.needsLayout = true
        self.needsDisplay = true
        self.layoutSubtreeIfNeeded()
    }

    func valuesForTesting() -> [String] {
        let rows = self.presentation.rows
        if rows.count > 1 {
            return rows.map { row in
                row.marker.map { "\($0) \(row.value)" } ?? row.value
            }
        }
        guard let row = rows.first else { return [] }
        return [row.value] + (row.resetText.map { [$0] } ?? [])
    }

    func topFontSizeForTesting() -> CGFloat {
        self.topLabel.font?.pointSize ?? 0
    }

    func hasBrandIconForTesting() -> Bool {
        self.iconView.image != nil && AppBrandIcon.isAvailable
    }

    override func layout() {
        super.layout()
        let rows = self.presentation.rows
        let hasTwoRows = rows.count > 1
        if hasTwoRows {
            self.iconView.frame = NSRect(x: 0, y: 11, width: 9, height: 9)
            self.topLabel.frame = NSRect(x: 11, y: 9.5, width: 34, height: 11)
            self.bottomMarker.frame = NSRect(x: 1, y: 0.5, width: 10, height: 10)
            self.bottomLabel.frame = NSRect(x: 12, y: 0, width: 34, height: 11)
        } else if rows.first?.resetText != nil {
            self.iconView.frame = NSRect(x: 0, y: 10, width: 11, height: 11)
            self.topLabel.frame = NSRect(x: 13, y: 7.5, width: 33, height: 15)
            self.bottomMarker.frame = NSRect(x: 0, y: -0.5, width: 46, height: 10)
            self.bottomLabel.frame = .zero
        } else {
            self.iconView.frame = NSRect(x: 0, y: 6, width: 12, height: 12)
            self.topLabel.frame = NSRect(x: 14, y: 3.5, width: 32, height: 17)
            self.bottomMarker.frame = .zero
            self.bottomLabel.frame = .zero
        }
    }

    private func configure() {
        self.translatesAutoresizingMaskIntoConstraints = false
        self.setAccessibilityElement(true)
        self.setAccessibilityRole(.staticText)
        self.setAccessibilityIdentifier("codexbalance.status-meter")

        self.iconView.image = AppBrandIcon.image(size: 10)
        self.iconView.imageScaling = .scaleProportionallyDown
        self.iconView.contentTintColor = .labelColor
        self.addSubview(self.iconView)

        for label in [self.topLabel, self.bottomLabel] {
            label.textColor = .labelColor
            label.alignment = .left
            label.lineBreakMode = .byClipping
            self.addSubview(label)
        }
        self.bottomMarker.lineBreakMode = .byClipping
        self.addSubview(self.bottomMarker)
        self.applyPresentation()
    }

    private func applyPresentation() {
        let rows = self.presentation.rows
        if rows.count > 1 {
            self.topLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
            self.bottomLabel.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
            self.bottomMarker.font = .systemFont(ofSize: 8.5, weight: .bold)
            self.bottomMarker.textColor = .labelColor
            self.bottomMarker.alignment = .left
            self.topLabel.stringValue = rows[0].value
            self.bottomMarker.stringValue = rows[1].marker ?? "W"
            self.bottomLabel.stringValue = rows[1].value
            self.topLabel.isHidden = false
            self.bottomMarker.isHidden = false
            self.bottomLabel.isHidden = false
        } else if let row = rows.first {
            let hasReset = row.resetText != nil
            self.topLabel.font = .monospacedDigitSystemFont(
                ofSize: hasReset ? 13 : 14,
                weight: .bold)
            self.topLabel.stringValue = row.value
            self.topLabel.isHidden = false
            self.bottomMarker.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
            self.bottomMarker.textColor = NSColor.labelColor.withAlphaComponent(0.82)
            self.bottomMarker.alignment = .center
            self.bottomMarker.stringValue = row.resetText ?? ""
            self.bottomMarker.isHidden = !hasReset
            self.bottomLabel.isHidden = true
        } else {
            self.topLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
            self.topLabel.stringValue = rows.first?.value ?? "--"
            self.topLabel.isHidden = false
            self.bottomMarker.isHidden = true
            self.bottomLabel.isHidden = true
        }
        self.alphaValue = self.presentation.isRefreshing ? 0.78 : 1
        self.setAccessibilityLabel(self.presentation.accessibilityText)
        self.toolTip = self.presentation.accessibilityText
    }
}
