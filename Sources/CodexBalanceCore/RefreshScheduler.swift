import Combine
import Foundation

public enum RefreshMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic = "Auto"
    case seconds30 = "30s"
    case minute1 = "1m"
    case minutes5 = "5m"
    case manual = "Manual"

    public var id: String { self.rawValue }
    public var label: String { self.rawValue }

    public var fixedInterval: TimeInterval? {
        switch self {
        case .automatic: nil
        case .seconds30: 30
        case .minute1: 60
        case .minutes5: 300
        case .manual: nil
        }
    }
}

public enum UserPresenceState: String, Codable, Sendable, Equatable {
    case active
    case idle
    case locked
    case asleep
    case screensaver
    case suspended

    public var pausesAutomaticRefresh: Bool {
        self != .active
    }

    public var pauseReason: String? {
        switch self {
        case .active: nil
        case .idle: "Paused while this Mac is idle"
        case .locked: "Paused while this Mac is locked"
        case .asleep: "Paused while the display sleeps"
        case .screensaver: "Paused while the screen saver is active"
        case .suspended: "Paused while this Mac sleeps"
        }
    }
}

public struct RefreshJitter: Sendable {
    public let fraction: Double

    public init(fraction: Double = 0.08) {
        self.fraction = min(0.25, max(0, fraction))
    }

    public func apply(to interval: TimeInterval, unit: Double) -> TimeInterval {
        let clampedUnit = min(1, max(0, unit))
        let centered = (clampedUnit * 2) - 1
        return max(1, interval * (1 + centered * self.fraction))
    }
}

public struct RefreshBackoffPolicy: Sendable {
    public let maximumInterval: TimeInterval

    public init(maximumInterval: TimeInterval = 15 * 60) {
        self.maximumInterval = max(60, maximumInterval)
    }

    public func interval(base: TimeInterval, failureCount: Int) -> TimeInterval {
        guard failureCount > 0 else { return base }
        return min(self.maximumInterval, base * pow(2, Double(min(failureCount, 4))))
    }
}

@MainActor
public final class RefreshScheduler: ObservableObject {
    @Published public private(set) var mode: RefreshMode
    @Published public private(set) var presence: UserPresenceState = .active
    @Published public private(set) var nextRefreshAt: Date?
    @Published public private(set) var lastRefreshAt: Date?
    @Published public private(set) var lastAttemptSucceeded: Bool?
    @Published public private(set) var isDashboardVisible = false

    private let store: UsageStore
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let jitterUnit: @Sendable () -> Double
    private let jitter: RefreshJitter
    private let backoff: RefreshBackoffPolicy
    private let adaptivePolicy: AdaptiveRefreshPolicy?
    private var timer: Timer?
    private var refreshTask: Task<Bool, Never>?
    private var failureCount = 0
    private var unchangedChecks = 0
    private var recentActivityUntil: Date?
    private var isStarted = false

    private static let modeKey = "CodexBalance.codexRefreshMode.v1"

    public init(
        store: UsageStore,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        jitterUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        jitter: RefreshJitter = RefreshJitter(),
        backoff: RefreshBackoffPolicy = RefreshBackoffPolicy(),
        adaptivePolicy: AdaptiveRefreshPolicy? = nil)
    {
        self.store = store
        self.defaults = defaults
        self.now = now
        self.jitterUnit = jitterUnit
        self.jitter = jitter
        self.backoff = backoff
        self.adaptivePolicy = adaptivePolicy
        self.mode = defaults.string(forKey: Self.modeKey)
            .flatMap(RefreshMode.init(rawValue:)) ?? .automatic
    }

    public func start() {
        guard !self.isStarted else { return }
        self.isStarted = true
        _ = self.beginRefresh()
    }

    public func stop() {
        self.isStarted = false
        self.timer?.invalidate()
        self.timer = nil
        self.nextRefreshAt = nil
        self.refreshTask?.cancel()
        self.refreshTask = nil
    }

    public func setMode(_ mode: RefreshMode) {
        self.mode = mode
        self.defaults.set(mode.rawValue, forKey: Self.modeKey)
        self.scheduleNext()
    }

    public func setDashboardVisible(_ visible: Bool) {
        let wasVisible = self.isDashboardVisible
        self.isDashboardVisible = visible
        guard visible, !wasVisible, self.isStarted, self.adaptivePolicy != nil,
              self.refreshTask == nil,
              self.presence == .active
        else { return }
        if self.store.observationState.lastCheckedAt == nil
            || self.now().timeIntervalSince(self.store.observationState.lastCheckedAt!) > 3
        {
            _ = self.beginRefresh()
        }
    }

    /// Called by a local activity observer; coalesces an activity burst into
    /// one later quota refresh without coupling analytics scanning to quota cadence.
    public func noteLocalActivity() {
        guard self.adaptivePolicy != nil else { return }
        self.recentActivityUntil = self.now().addingTimeInterval(120)
        self.timer?.invalidate()
        self.timer = nil
        self.nextRefreshAt = self.now().addingTimeInterval(2.5)
        self.timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor in _ = self?.beginRefresh() }
        }
    }

    public func updatePresence(_ presence: UserPresenceState) {
        let wasPaused = self.presence.pausesAutomaticRefresh
        self.presence = presence
        if presence.pausesAutomaticRefresh {
            self.timer?.invalidate()
            self.timer = nil
            self.nextRefreshAt = nil
        } else if wasPaused, self.isStarted {
            if self.adaptivePolicy != nil {
                self.scheduleAfter(2)
            } else {
                _ = self.beginRefresh()
            }
        } else {
            self.scheduleNext()
        }
    }

    @discardableResult
    public func refreshNow() -> Bool {
        self.beginRefresh() != nil
    }

    @discardableResult
    public func refreshNowAndWait() async -> Bool {
        if let refreshTask {
            return await refreshTask.value
        }
        guard let task = self.beginRefresh() else { return false }
        return await task.value
    }

    public func countdownText(now: Date = Date()) -> String {
        if let reason = self.presence.pauseReason { return reason }
        if self.mode == .manual { return "Manual refresh" }
        guard let nextRefreshAt else {
            return self.store.isRefreshing ? "Refreshing..." : "Scheduling next refresh"
        }
        return "Next refresh in \(UsageSnapshot.countdown(to: nextRefreshAt, now: now))"
    }

    public func nextIntervalForTesting() -> TimeInterval? {
        self.nextInterval()
    }

    public func fireScheduledRefreshForTesting() {
        guard self.isStarted else { return }
        _ = self.beginRefresh()
    }

    private func beginRefresh() -> Task<Bool, Never>? {
        guard self.refreshTask == nil else { return nil }
        guard !self.presence.pausesAutomaticRefresh else {
            self.scheduleNext()
            return nil
        }
        // Publish the visible feedback before scheduling asynchronous provider
        // work so the Refresh control responds within the UI event turn.
        guard self.store.beginRefreshing() else { return nil }
        self.timer?.invalidate()
        self.timer = nil
        self.nextRefreshAt = nil

        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            let previousChange = self.store.lastQuotaChangedAt
            let success = await self.store.refresh(alreadyMarkedRefreshing: true)
            guard !Task.isCancelled else {
                self.refreshTask = nil
                self.scheduleNext()
                return false
            }
            self.lastRefreshAt = self.now()
            self.lastAttemptSucceeded = success
            self.failureCount = success ? 0 : self.failureCount + 1
            if success {
                if self.store.lastQuotaChangedAt != previousChange {
                    self.unchangedChecks = 0
                    self.recentActivityUntil = self.now().addingTimeInterval(120)
                } else {
                    self.unchangedChecks += 1
                }
            }
            self.refreshTask = nil
            self.scheduleNext()
            return success
        }
        self.refreshTask = task
        return task
    }

    private func scheduleNext() {
        self.timer?.invalidate()
        self.timer = nil
        self.nextRefreshAt = nil
        guard self.isStarted,
              !self.presence.pausesAutomaticRefresh,
              self.refreshTask == nil,
              let interval = self.nextInterval()
        else { return }

        let fireAt = self.now().addingTimeInterval(interval)
        self.nextRefreshAt = fireAt
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                _ = self?.beginRefresh()
            }
        }
    }

    private func scheduleAfter(_ interval: TimeInterval) {
        self.timer?.invalidate()
        self.timer = nil
        guard self.isStarted, !self.presence.pausesAutomaticRefresh else { return }
        self.nextRefreshAt = self.now().addingTimeInterval(interval)
        self.timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in _ = self?.beginRefresh() }
        }
    }

    private func nextInterval() -> TimeInterval? {
        if self.mode == .manual { return nil }
        if let adaptivePolicy {
            let activeUntil = self.recentActivityUntil ?? .distantPast
            let decision = adaptivePolicy.decide(AdaptiveRefreshInput(
                now: self.now(),
                dashboardVisible: self.isDashboardVisible,
                presence: self.presence,
                hasRecentActivity: activeUntil > self.now(),
                unchangedChecks: self.unchangedChecks,
                lastCheckedAt: self.store.observationState.lastCheckedAt,
                isInFlight: self.refreshTask != nil,
                cooldownUntil: nil), jitterUnit: self.jitterUnit())
            return decision.nextInterval
        }
        let base: TimeInterval
        if let fixedInterval = self.mode.fixedInterval {
            base = fixedInterval
        } else if self.store.snapshot.errorMessage != nil || self.store.snapshot.isStale {
            base = 5 * 60
        } else if let session = self.store.snapshot.sessionPercentRemaining, session <= 20 {
            base = 30
        } else {
            base = 60
        }
        let backedOff = self.backoff.interval(base: base, failureCount: self.failureCount)
        return self.jitter.apply(to: backedOff, unit: self.jitterUnit())
    }
}
