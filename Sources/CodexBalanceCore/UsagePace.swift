import Foundation

public struct UsagePace: Equatable, Sendable {
    public enum Balance: Equatable, Sendable {
        case reserve(Double)
        case deficit(Double)
        case onTarget
    }

    public let elapsedWindowPercent: Double
    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    public let balance: Balance
    public let projectedEmptyAt: Date?
    public let lastsUntilReset: Bool

    public init?(
        window: UsageWindow,
        now: Date = Date())
    {
        guard let resetAt = window.resetAt,
              let windowSeconds = window.windowSeconds,
              windowSeconds > 0
        else {
            return nil
        }

        let duration = TimeInterval(windowSeconds)
        let startAt = resetAt.addingTimeInterval(-duration)
        let elapsed = min(duration, max(0, now.timeIntervalSince(startAt)))
        let elapsedPercent = UsageWindow.clampPercent((elapsed / duration) * 100)
        let actualUsed = UsageWindow.clampPercent(window.usedPercent)
        let expectedUsed = UsageWindow.clampPercent(elapsedPercent)
        let delta = actualUsed - expectedUsed

        self.elapsedWindowPercent = elapsedPercent
        self.expectedUsedPercent = expectedUsed
        self.actualUsedPercent = actualUsed

        if delta > 0.5 {
            self.balance = .deficit(delta)
        } else if delta < -0.5 {
            self.balance = .reserve(abs(delta))
        } else {
            self.balance = .onTarget
        }

        if actualUsed <= 0 || elapsed <= 0 {
            self.projectedEmptyAt = nil
            self.lastsUntilReset = true
        } else {
            let totalSecondsAtCurrentPace = elapsed * (100 / actualUsed)
            let projected = startAt.addingTimeInterval(totalSecondsAtCurrentPace)
            self.projectedEmptyAt = projected
            self.lastsUntilReset = projected >= resetAt
        }
    }

    public var targetRemainingPercent: Double {
        UsageWindow.clampPercent(100 - self.expectedUsedPercent)
    }
}

public enum UsagePaceFormatter {
    public static func decisionText(_ pace: UsagePace) -> String {
        if !pace.lastsUntilReset {
            return "Low quota"
        }
        switch pace.balance {
        case .reserve, .onTarget:
            return "Can keep working"
        case .deficit:
            return "Watch pace"
        }
    }

    public static func balanceText(_ pace: UsagePace) -> String {
        switch pace.balance {
        case let .reserve(value):
            "\(Self.roundedPercent(value))% in reserve"
        case let .deficit(value):
            "\(Self.roundedPercent(value))% in deficit"
        case .onTarget:
            "On target"
        }
    }

    public static func expectedUsedText(_ pace: UsagePace) -> String {
        "Expected \(Self.roundedPercent(pace.expectedUsedPercent))% used"
    }

    public static func projectionText(_ pace: UsagePace, now: Date = Date()) -> String {
        if pace.lastsUntilReset {
            return "Lasts until reset"
        }
        guard let projectedEmptyAt = pace.projectedEmptyAt else {
            return "Lasts until reset"
        }
        return "Runs out in \(UsageSnapshot.countdown(to: projectedEmptyAt, now: now))"
    }

    private static func roundedPercent(_ value: Double) -> Int {
        Int(UsageWindow.clampPercent(value).rounded())
    }
}
