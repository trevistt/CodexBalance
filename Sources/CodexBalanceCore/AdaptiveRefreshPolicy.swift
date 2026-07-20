import Foundation

public enum AdaptiveRefreshTrigger: Equatable, Sendable {
    case automatic
    case panelOpened
    case manual
    case localActivity
    case wakeOrUnlock
}

public struct AdaptiveRefreshInput: Equatable, Sendable {
    public var now: Date
    public var dashboardVisible: Bool
    public var presence: UserPresenceState
    public var hasRecentActivity: Bool
    public var unchangedChecks: Int
    public var lastCheckedAt: Date?
    public var isInFlight: Bool
    public var cooldownUntil: Date?
    public var trigger: AdaptiveRefreshTrigger

    public init(now: Date, dashboardVisible: Bool, presence: UserPresenceState, hasRecentActivity: Bool, unchangedChecks: Int, lastCheckedAt: Date?, isInFlight: Bool, cooldownUntil: Date?, trigger: AdaptiveRefreshTrigger = .automatic) {
        self.now = now
        self.dashboardVisible = dashboardVisible
        self.presence = presence
        self.hasRecentActivity = hasRecentActivity
        self.unchangedChecks = unchangedChecks
        self.lastCheckedAt = lastCheckedAt
        self.isInFlight = isInFlight
        self.cooldownUntil = cooldownUntil
        self.trigger = trigger
    }
}

public struct AdaptiveRefreshDecision: Equatable, Sendable {
    public let refreshNow: Bool
    public let nextInterval: TimeInterval?
    public let reason: String

    public init(refreshNow: Bool, nextInterval: TimeInterval?, reason: String) {
        self.refreshNow = refreshNow
        self.nextInterval = nextInterval
        self.reason = reason
    }
}

/// Pure policy. The caller owns timers, source cascade and all side effects.
public struct AdaptiveRefreshPolicy: Sendable {
    public let jitterFraction: Double

    public init(jitterFraction: Double = 0.10) {
        self.jitterFraction = min(0.10, max(0, jitterFraction))
    }

    public func decide(_ input: AdaptiveRefreshInput, jitterUnit: Double = 0.5) -> AdaptiveRefreshDecision {
        if input.presence.pausesAutomaticRefresh {
            return .init(refreshNow: false, nextInterval: nil, reason: input.presence.pauseReason ?? "Paused")
        }
        if input.isInFlight { return .init(refreshNow: false, nextInterval: nil, reason: "Refresh already in progress") }
        if let cooldownUntil = input.cooldownUntil, cooldownUntil > input.now {
            return .init(refreshNow: false, nextInterval: cooldownUntil.timeIntervalSince(input.now), reason: "Source cooldown")
        }
        switch input.trigger {
        case .manual: return .init(refreshNow: true, nextInterval: nil, reason: "Manual refresh")
        case .panelOpened:
            if input.lastCheckedAt == nil || input.now.timeIntervalSince(input.lastCheckedAt!) > 3 {
                return .init(refreshNow: true, nextInterval: nil, reason: "Panel opened")
            }
        case .localActivity:
            return .init(refreshNow: false, nextInterval: 2.5, reason: "Debounced local activity")
        case .wakeOrUnlock:
            return .init(refreshNow: false, nextInterval: 2, reason: "Wake settle")
        case .automatic: break
        }
        let base: TimeInterval
        if input.dashboardVisible { base = 10 }
        else if input.hasRecentActivity { base = 15 }
        else if input.unchangedChecks >= 3 { base = 60 }
        else { base = 15 }
        return .init(refreshNow: false, nextInterval: self.jitter(base, unit: jitterUnit), reason: "Adaptive cadence")
    }

    public func allowsDurableWrite(at now: Date, previousWrites: [Date]) -> Bool {
        previousWrites.filter { now.timeIntervalSince($0) < 60 }.count < 2
    }

    private func jitter(_ interval: TimeInterval, unit: Double) -> TimeInterval {
        let clamped = min(1, max(0, unit))
        return interval * (1 + ((clamped * 2) - 1) * self.jitterFraction)
    }
}
