import Foundation

public struct UsageDecision: Equatable, Sendable {
    public let headline: String
    public let supportingText: String
    public let observationText: String
    public let isCaution: Bool

    public init(headline: String, supportingText: String, observationText: String, isCaution: Bool) {
        self.headline = headline
        self.supportingText = supportingText
        self.observationText = observationText
        self.isCaution = isCaution
    }
}

public enum UsageDecisionEngine {
    public static func make(
        snapshot: UsageSnapshot,
        observation: UsageObservationState,
        now: Date = Date()) -> UsageDecision
    {
        if snapshot.source == .loading {
            return UsageDecision(
                headline: "Checking Codex quota",
                supportingText: "Waiting for the first complete usage result.",
                observationText: "Establishing change history",
                isCaution: false)
        }
        guard snapshot.hasAnyQuota else {
            return UsageDecision(
                headline: "Quota unavailable",
                supportingText: "Wait for a complete Codex usage result.",
                observationText: observation.lastCheckedAt == nil ? "Establishing change history" : "Last check did not provide quota",
                isCaution: true)
        }
        let limiting = [snapshot.sessionWindow(), snapshot.weeklyWindow()]
            .compactMap { $0 }
            .min { $0.remainingPercent < $1.remainingPercent }
        let pace = limiting.flatMap { UsagePace(window: $0, now: now) }
        let headline: String
        let detail: String
        let caution: Bool
        if snapshot.isStale {
            headline = "Use cached quota with care"
            detail = "Cached from \(UsageSnapshot.countdown(to: snapshot.verifiedAt ?? snapshot.updatedAt, now: now)) ago"
            caution = true
        } else if let pace, !pace.lastsUntilReset {
            headline = "Watch quota pace"
            detail = UsagePaceFormatter.projectionText(pace, now: now)
            caution = true
        } else {
            headline = "Can keep working"
            detail = pace.map(UsagePaceFormatter.balanceText) ?? "Reset time is still useful"
            caution = false
        }
        let observationText: String
        if observation.lastCheckedAt == nil {
            observationText = "Establishing change history"
        } else if let changedAt = observation.lastChangedAt,
                  observation.lastCheckedAt.map({ changedAt >= $0.addingTimeInterval(-1) }) == true,
                  observation.observations.count >= 2
        {
            observationText = "Quota changed since the prior successful check"
        } else {
            observationText = "Checked just now - no quota change"
        }
        return UsageDecision(headline: headline, supportingText: detail, observationText: observationText, isCaution: caution)
    }
}
