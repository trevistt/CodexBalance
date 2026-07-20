import AppKit
import CodexBalanceCore

enum UIQAFixtureLaunch: Equatable {
    case production
    case fixture(nonce: String, state: String)
    case invalid

    static func parse(arguments: [String]) -> UIQAFixtureLaunch {
        let nonceArgument = arguments.first { $0.hasPrefix("--ui-qa-fixture=") }
        let stateArgument = arguments.first { $0.hasPrefix("--ui-qa-state=") }
        guard nonceArgument != nil || stateArgument != nil else { return .production }
        guard let rawNonce = nonceArgument?.replacingOccurrences(of: "--ui-qa-fixture=", with: ""),
              let uuid = UUID(uuidString: rawNonce),
              let state = stateArgument?.replacingOccurrences(of: "--ui-qa-state=", with: ""),
              !state.isEmpty
        else { return .invalid }
        return .fixture(nonce: uuid.uuidString.lowercased(), state: state)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var usageStore: UsageStore?
    private var analyticsStore: LocalUsageAnalyticsStore?
    private var scheduler: RefreshScheduler?
    private var analyticsScheduler: LocalUsageAnalyticsScheduler?
    private var statusItemController: StatusItemController?
    private var notchPillController: NotchPillController?
    private var presenceMonitor: UserPresenceMonitor?
    private var localUsageActivityMonitor: LocalUsageActivityMonitor?
    private var screenObserver: NSObjectProtocol?
    private var fixtureBackdrop: NSWindow?
    private var didBootstrap = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.bootstrap()
    }

    /// Startup notifications for accessory menu-bar apps can arrive before a
    /// delegate is attached. The main entry point also calls this idempotent
    /// bootstrap so the initial refresh cannot be missed.
    func bootstrap() {
        guard !self.didBootstrap else { return }
        self.didBootstrap = true
        let env = ProcessInfo.processInfo.environment
        let arguments = ProcessInfo.processInfo.arguments
        let fixtureLaunch = UIQAFixtureLaunch.parse(arguments: arguments)
        if fixtureLaunch == .invalid {
            fputs("CodexBalance fixture launch rejected: invalid isolated fixture arguments.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let fixtureNonce: String?
        let fixtureState: String?
        switch fixtureLaunch {
        case let .fixture(nonce, state):
            fixtureNonce = nonce
            fixtureState = state
        case .production, .invalid:
            fixtureNonce = nil
            fixtureState = nil
        }
        ShortcutDiagnosticTrace.configure(arguments: arguments, fixtureNonce: fixtureNonce)
        let forcedIdleFixture = fixtureNonce != nil && arguments.contains("--ui-qa-presence=idle")
        let appearanceArgument = Self.argumentValue("--ui-qa-appearance=", arguments: arguments)
        let maxHeightArgument = Self.argumentValue("--ui-qa-panel-max-height=", arguments: arguments)
        guard fixtureNonce != nil || (appearanceArgument == nil && maxHeightArgument == nil) else {
            fputs("CodexBalance fixture launch rejected: QA display arguments require an isolated fixture.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        guard appearanceArgument == nil || appearanceArgument == "light" || appearanceArgument == "dark" else {
            fputs("CodexBalance fixture launch rejected: invalid QA appearance.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        let fixturePanelMaxHeight = maxHeightArgument.flatMap(Double.init).map { CGFloat($0) }
        guard maxHeightArgument == nil || fixturePanelMaxHeight.map({
            $0 >= 360 && $0 <= HoverPanelView.naturalHeight
        }) == true else {
            fputs("CodexBalance fixture launch rejected: invalid QA panel height.\n", stderr)
            NSApp.terminate(nil)
            return
        }
        if appearanceArgument == "light" {
            NSApp.appearance = NSAppearance(named: .aqua)
        } else if appearanceArgument == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        let usageResolver = Self.makeUsageResolver(
            env: env,
            arguments: arguments,
            fixtureState: fixtureState)
        let analyticsProvider = Self.makeAnalyticsProvider(
            env: env,
            arguments: arguments,
            fixtureState: fixtureState)
        let usageCacheURL = fixtureNonce.map {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-balance-codex-ui-\($0)-usage.json")
        }
        let analyticsCacheURL = fixtureNonce.map {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-balance-codex-ui-\($0)-analytics.json")
        }
        let observationCacheURL = fixtureNonce.map {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("codex-balance-codex-ui-\($0)-observations.json")
        }
        let fixtureDefaults = fixtureNonce.flatMap {
            UserDefaults(suiteName: "CodexBalance.UIQA.\($0)")
        }

        let usageStore = UsageStore(
            resolver: usageResolver,
            cache: UsageSnapshotCache(url: usageCacheURL),
            observationCache: UsageObservationCache(url: observationCacheURL))
        let analyticsStore = LocalUsageAnalyticsStore(
            provider: analyticsProvider,
            cache: LocalUsageAnalyticsCache(url: analyticsCacheURL))
        let adaptiveRefreshEnabled = CodexBalanceEnvironment
            .value("CODEX_BALANCE_ENABLE_ADAPTIVE_REFRESH", in: env) != "0"
        let scheduler = RefreshScheduler(
            store: usageStore,
            defaults: fixtureDefaults ?? .standard,
            adaptivePolicy: adaptiveRefreshEnabled
                ? AdaptiveRefreshPolicy()
                : nil)
        let analyticsScheduler = LocalUsageAnalyticsScheduler(store: analyticsStore)
        let pinState = DashboardPinState(defaults: fixtureDefaults ?? .standard)

        self.usageStore = usageStore
        self.analyticsStore = analyticsStore
        self.scheduler = scheduler
        self.analyticsScheduler = analyticsScheduler
        self.statusItemController = StatusItemController(
            usageStore: usageStore,
            scheduler: scheduler,
            analyticsStore: analyticsStore,
            analyticsScheduler: analyticsScheduler,
            pinState: pinState,
            maxPanelHeightOverride: fixturePanelMaxHeight)

        if forcedIdleFixture {
            // Start the deterministic fixture once before pausing subsequent
            // refreshes so the UI has a complete snapshot to exercise.
        } else if fixtureNonce == nil {
            self.presenceMonitor = UserPresenceMonitor { [weak scheduler] state in
                scheduler?.updatePresence(state)
            }
            self.presenceMonitor?.start()
        }
        // A UI fixture must remain isolated from the owner's changing local
        // Codex tree; production adaptive mode still monitors recursively.
        if fixtureNonce == nil, adaptiveRefreshEnabled
        {
            self.localUsageActivityMonitor = LocalUsageActivityMonitor(
                roots: CodexLocalLogAnalyticsProvider.codexRoots(env: env),
                onActivity: { Task { @MainActor [weak scheduler] in scheduler?.noteLocalActivity() } })
            self.localUsageActivityMonitor?.start()
        }

        if CodexBalanceEnvironment.isEnabled("CODEX_BALANCE_SHOW_NOTCH", in: env) {
            self.notchPillController = NotchPillController(
                usageStore: usageStore,
                scheduler: scheduler,
                analyticsStore: analyticsStore,
                analyticsScheduler: analyticsScheduler,
                pinState: pinState)
            self.notchPillController?.showIfAvailable()
            self.screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.notchPillController?.showIfAvailable()
                    }
                }
        }

        if let fixtureNonce {
            let appearance = appearanceArgument ?? "system"
            self.showFixtureBackdrop(nonce: fixtureNonce, appearance: appearance)
            fputs(
                "UI_QA_FIXTURE_CONFIG appearance=\(appearance) " +
                    "max_panel_height=\(fixturePanelMaxHeight.map { String(Int($0)) } ?? "system")\n",
                stderr)
        }
        scheduler.start()
        if forcedIdleFixture {
            scheduler.updatePresence(.idle)
            ShortcutDiagnosticTrace.record(
                "fixture.presence.forced",
                fields: ["presence": "idle"])
        }
        analyticsScheduler.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.scheduler?.stop()
        self.analyticsScheduler?.stop()
        self.presenceMonitor?.stop()
        self.localUsageActivityMonitor?.stop()
        self.statusItemController?.invalidate()
        self.notchPillController?.close()
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    private static func makeUsageResolver(
        env: [String: String],
        arguments: [String],
        fixtureState: String?) -> any CodexUsageResolving
    {
        if let fixtureState {
            return SingleCodexUsageResolver(provider: UIQAFixtureUsageProvider(state: fixtureState))
        }
        let fixture = CodexBalanceEnvironment.value("CODEX_BALANCE_FIXTURE", in: env)
            ?? Self.argumentValue("--fixture=", arguments: arguments)
        if let fixture {
            return SingleCodexUsageResolver(provider: FixtureCodexUsageProvider(
                mode: FixtureCodexUsageProvider.Mode(rawValue: fixture) ?? .success))
        }
        return CodexUsageResolver(sources: [
            .init(kind: .oauth, provider: OAuthCodexUsageProvider(env: env, httpClient: URLSessionUsageHTTPClient())),
            .init(kind: .cliRPC, provider: CLIRPCCodexUsageProvider(env: env)),
            .init(kind: .localFallback, provider: LocalCodexUsageProvider(env: env)),
        ])
    }

    private static func makeAnalyticsProvider(
        env: [String: String],
        arguments: [String],
        fixtureState: String?) -> any LocalUsageAnalyticsProviding
    {
        if let fixtureState {
            if fixtureState == "analytics-error" {
                return FixtureLocalUsageAnalyticsProvider(mode: .error)
            }
            if fixtureState == "analytics-empty" {
                return FixtureLocalUsageAnalyticsProvider(mode: .empty)
            }
            return FixtureLocalUsageAnalyticsProvider(mode: .full)
        }
        if let mode = CodexBalanceEnvironment.value("CODEX_BALANCE_ANALYTICS_FIXTURE", in: env)
            ?? Self.argumentValue("--analytics-fixture=", arguments: arguments)
        {
            return FixtureLocalUsageAnalyticsProvider(
                mode: FixtureLocalUsageAnalyticsProvider.Mode(rawValue: mode) ?? .full)
        }
        return CodexLocalLogAnalyticsProvider(env: env)
    }

    private static func argumentValue(_ prefix: String, arguments: [String]) -> String? {
        arguments.first(where: { $0.hasPrefix(prefix) })?
            .replacingOccurrences(of: prefix, with: "")
    }

    private func showFixtureBackdrop(nonce: String, appearance: String) {
        guard let screen = NSScreen.main else { return }
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.backgroundColor = appearance == "light"
            ? NSColor(calibratedWhite: 0.96, alpha: 1)
            : NSColor(calibratedRed: 0.025, green: 0.028, blue: 0.038, alpha: 1)
        window.isOpaque = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        marker.setAccessibilityElement(true)
        marker.setAccessibilityRole(.staticText)
        marker.setAccessibilityIdentifier("codexbalance.ui-qa.fixture")
        marker.setAccessibilityLabel("CodexBalance Codex-only UI QA fixture")
        marker.setAccessibilityValue(nonce)
        window.contentView?.addSubview(marker)
        window.orderFront(nil)
        self.fixtureBackdrop = window
    }
}

private struct UIQAFixtureUsageProvider: CodexUsageProviding {
    let state: String

    func fetchUsage() async throws -> UsageSnapshot {
        let now = Date()
        let healthy = UsageSnapshot(
            sessionPercentRemaining: 63,
            weeklyPercentRemaining: 39,
            sessionResetAt: now.addingTimeInterval(2 * 3_600 + 20 * 60),
            weeklyResetAt: now.addingTimeInterval(3 * 86_400 + 5 * 3_600),
            extraWindows: [
                UsageNamedWindow(
                    id: "codex-spark",
                    title: "Codex Spark 5-hour",
                    window: UsageWindow(
                        usedPercent: 28,
                        resetAt: now.addingTimeInterval(3 * 3_600),
                        windowSeconds: 18_000)),
            ],
            source: .oauth,
            updatedAt: now)
        switch self.state {
        case "weekly-only":
            return UsageSnapshot(
                sessionPercentRemaining: nil,
                weeklyPercentRemaining: 43,
                sessionResetAt: nil,
                weeklyResetAt: now.addingTimeInterval(4 * 86_400),
                source: .oauth,
                updatedAt: now)
        case "loading":
            try await Task.sleep(for: .seconds(30))
            return healthy
        case "stale":
            return healthy.markedStale(
                errorMessage: "Codex refresh is temporarily unavailable.",
                updatedAt: now.addingTimeInterval(-600))
        case "error":
            throw CodexUsageProviderError.processFailed("Synthetic provider failure.")
        case "unavailable":
            throw CodexUsageProviderError.noUsageWindows
        default:
            // Keep the success fixture briefly in-flight so the real AppKit
            // driver can verify immediate Refresh feedback without using a
            // network or a long startup delay.
            try await Task.sleep(for: .milliseconds(120))
            return healthy
        }
    }
}
