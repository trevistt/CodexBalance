import Foundation

public struct UsageDiagnosticsState: Equatable, Sendable {
    public let source: String
    public let freshness: String
    public let lastSuccessfulRefreshAt: Date?
    public let lastErrorCategory: String
    public let nextRefreshSummary: String
    public let refreshMode: String
    public let presence: String
    public let analyticsSource: String
    public let analyticsUpdatedAt: Date?
    public let analyticsStatus: String

    public init(
        source: String,
        freshness: String,
        lastSuccessfulRefreshAt: Date?,
        lastErrorCategory: String,
        nextRefreshSummary: String,
        refreshMode: String,
        presence: String,
        analyticsSource: String,
        analyticsUpdatedAt: Date?,
        analyticsStatus: String)
    {
        self.source = UsageSnapshot.sanitized(source)
        self.freshness = UsageSnapshot.sanitized(freshness)
        self.lastSuccessfulRefreshAt = lastSuccessfulRefreshAt
        self.lastErrorCategory = UsageSnapshot.sanitized(lastErrorCategory)
        self.nextRefreshSummary = UsageSnapshot.sanitized(nextRefreshSummary)
        self.refreshMode = UsageSnapshot.sanitized(refreshMode)
        self.presence = UsageSnapshot.sanitized(presence)
        self.analyticsSource = UsageSnapshot.sanitized(analyticsSource)
        self.analyticsUpdatedAt = analyticsUpdatedAt
        self.analyticsStatus = UsageSnapshot.sanitized(analyticsStatus)
    }
}

public enum UsageDiagnosticsFormatter {
    public static func state(
        snapshot: UsageSnapshot,
        storeLastSuccess: Date?,
        storeLastError: String?,
        mode: RefreshMode,
        presence: UserPresenceState,
        nextRefreshAt: Date?,
        analytics: LocalUsageAnalyticsSnapshot,
        analyticsLastSuccess: Date?,
        now: Date = Date()) -> UsageDiagnosticsState
    {
        let freshness: String
        if snapshot.isStale {
            let age = max(0, now.timeIntervalSince(snapshot.verifiedAt ?? snapshot.updatedAt))
            freshness = "Cached, \(Self.ageText(age)) old"
        } else if snapshot.hasAnyQuota {
            freshness = "Live, updated \(Self.ageText(max(0, now.timeIntervalSince(snapshot.updatedAt)))) ago"
        } else {
            freshness = "Unavailable"
        }

        let nextRefreshSummary: String
        if let reason = presence.pauseReason {
            nextRefreshSummary = reason
        } else if mode == .manual {
            nextRefreshSummary = "Manual refresh"
        } else if let nextRefreshAt {
            nextRefreshSummary = "In \(UsageSnapshot.countdown(to: nextRefreshAt, now: now))"
        } else {
            nextRefreshSummary = "Scheduling"
        }

        let analyticsStatus: String
        if analytics.isStale {
            analyticsStatus = "Cached after scan error"
        } else if analytics.hasAnyData {
            analyticsStatus = analytics.isCostPartial ? "Available, partial estimate" : "Available"
        } else {
            analyticsStatus = "No local data"
        }

        return UsageDiagnosticsState(
            source: snapshot.sourceLabel,
            freshness: freshness,
            lastSuccessfulRefreshAt: storeLastSuccess,
            lastErrorCategory: Self.errorCategory(storeLastError ?? snapshot.errorMessage),
            nextRefreshSummary: nextRefreshSummary,
            refreshMode: mode.label,
            presence: presence.rawValue,
            analyticsSource: analytics.sourceLabel,
            analyticsUpdatedAt: analyticsLastSuccess ?? analytics.updatedAt,
            analyticsStatus: analyticsStatus)
    }

    public static func exportText(_ state: UsageDiagnosticsState) -> String {
        let lines = [
            "CodexBalance diagnostics",
            "Provider: OpenAI Codex",
            "Credential mode: automatic source cascade (OAuth, CLI RPC, local fallback)",
            "Quota source: \(state.source)",
            "Quota freshness: \(state.freshness)",
            "Last successful refresh: \(Self.dateText(state.lastSuccessfulRefreshAt))",
            "Last error category: \(state.lastErrorCategory)",
            "Refresh mode: \(state.refreshMode)",
            "Next refresh: \(state.nextRefreshSummary)",
            "Presence: \(state.presence)",
            "Analytics source: \(state.analyticsSource)",
            "Analytics updated: \(Self.dateText(state.analyticsUpdatedAt))",
            "Analytics status: \(state.analyticsStatus)",
            "Privacy: no tokens, headers, cookies, credential JSON, prompt text, or full paths included.",
        ]
        return UsageSnapshot.sanitized(lines.joined(separator: "\n"))
    }

    public static func errorCategory(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "None" }
        let lower = message.lowercased()
        if lower.contains("authorization") || lower.contains("unauthorized") || lower.contains("forbidden")
            || lower.contains("401") || lower.contains("403")
        {
            return "Authentication"
        }
        if lower.contains("credential") || lower.contains("auth.json") {
            return "Credentials unavailable"
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "Timeout"
        }
        if lower.contains("invalid") || lower.contains("decode") {
            return "Invalid response"
        }
        if lower.contains("cancel") {
            return "Cancelled"
        }
        return "Provider unavailable"
    }

    private static func ageText(_ interval: TimeInterval) -> String {
        if interval < 60 { return "under 1m" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        return "\(Int(interval / 86_400))d"
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return ISO8601DateFormatter().string(from: date)
    }
}
