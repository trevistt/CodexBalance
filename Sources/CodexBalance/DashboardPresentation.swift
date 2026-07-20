import Foundation
import CodexBalanceCore

enum DashboardPresentationTone: String, Equatable {
    case neutral
    case safe
    case caution
    case error
    case cached
}

struct DashboardStatusSlot: Equatable {
    let title: String
    let detail: String
    let symbol: String
    let tone: DashboardPresentationTone
}

struct DashboardQuotaRowPresentation: Identifiable {
    let row: UsageQuotaWindowPresentation.Row
    let pace: UsagePace?
    let isLimiting: Bool

    var id: String { self.row.role.rawValue }
}

/// Presentation-only adapter. It derives display values from existing Core
/// truth and intentionally owns no timer, persistence, I/O or refresh rule.
struct DashboardPresentation {
    let snapshot: UsageSnapshot
    let decision: UsageDecision
    let quotaRows: [DashboardQuotaRowPresentation]
    let runway: DashboardRunwayPresentation?
    let statusSlot: DashboardStatusSlot
    let headerStatus: String
    let observationText: String
    let observationDetail: String

    init(
        snapshot: UsageSnapshot,
        observation: UsageObservationState,
        isRefreshing: Bool,
        now: Date)
    {
        self.snapshot = snapshot
        self.decision = UsageDecisionEngine.make(
            snapshot: snapshot,
            observation: observation,
            now: now)

        let rows = UsageQuotaWindowPresentationResolver.resolve(snapshot: snapshot).rows
        let limitingRole = rows
            .filter { $0.remainingPercent != nil }
            .min { ($0.remainingPercent ?? 101) < ($1.remainingPercent ?? 101) }?
            .role
        let quotaRows = rows.map { row in
            DashboardQuotaRowPresentation(
                row: row,
                pace: row.window.flatMap { UsagePace(window: $0, now: now) },
                isLimiting: row.role == limitingRole)
        }
        self.quotaRows = quotaRows
        self.runway = quotaRows
            .first(where: \.isLimiting)
            .flatMap { DashboardRunwayPresentation(row: $0, isStale: snapshot.isStale, now: now) }
        self.headerStatus = Self.headerStatus(snapshot: snapshot, isRefreshing: isRefreshing, now: now)
        self.statusSlot = Self.statusSlot(snapshot: snapshot, isRefreshing: isRefreshing, now: now)
        self.observationText = self.decision.observationText
        self.observationDetail = Self.observationDetail(observation)
    }

    static func relativeAge(_ interval: TimeInterval) -> String {
        if interval < 60 { return "just now" }
        if interval < 3_600 { return "\(Int(interval / 60))m" }
        if interval < 86_400 { return "\(Int(interval / 3_600))h" }
        return "\(Int(interval / 86_400))d"
    }

    private static func headerStatus(
        snapshot: UsageSnapshot,
        isRefreshing: Bool,
        now: Date) -> String
    {
        if isRefreshing { return "Checking..." }
        if snapshot.isStale {
            let age = Self.relativeAge(max(0, now.timeIntervalSince(snapshot.verifiedAt ?? snapshot.updatedAt)))
            return "Cached - \(age) old"
        }
        guard snapshot.hasAnyQuota else { return "Usage unavailable" }
        let age = max(0, now.timeIntervalSince(snapshot.updatedAt))
        return age < 60 ? "Live - checked just now" : "Live - checked \(Self.relativeAge(age)) ago"
    }

    private static func statusSlot(
        snapshot: UsageSnapshot,
        isRefreshing: Bool,
        now: Date) -> DashboardStatusSlot
    {
        if snapshot.source == .loading || (isRefreshing && !snapshot.hasAnyQuota) {
            return DashboardStatusSlot(
                title: "Checking Codex quota",
                detail: "Waiting for the first complete usage result.",
                symbol: "arrow.triangle.2.circlepath",
                tone: .neutral)
        }
        if snapshot.isStale {
            let error = snapshot.errorMessage?.lowercased() ?? ""
            let age = Self.relativeAge(max(0, now.timeIntervalSince(snapshot.verifiedAt ?? snapshot.updatedAt)))
            if error.contains("rate limit") || error.contains("429") {
                return DashboardStatusSlot(
                    title: "Rate limited",
                    detail: snapshot.errorMessage ?? "Showing cached quota from \(age) ago. Wait for cooldown, then press Refresh.",
                    symbol: "clock.badge.exclamationmark",
                    tone: .cached)
            }
            if error.contains("authorization") || error.contains("unauthorized") || error.contains("forbidden") {
                return DashboardStatusSlot(
                    title: "Login needed",
                    detail: "Open Codex to refresh sign-in, then press Refresh. Cached quota is \(age) old.",
                    symbol: "key.fill",
                    tone: .caution)
            }
            return DashboardStatusSlot(
                title: "Cached quota",
                detail: "Last live value was checked \(age) ago.",
                symbol: "clock.arrow.circlepath",
                tone: .cached)
        }
        if snapshot.hasAnyQuota {
            return DashboardStatusSlot(
                title: "Live quota",
                detail: "Checked \(Self.relativeAge(max(0, now.timeIntervalSince(snapshot.updatedAt)))) ago.",
                symbol: "checkmark.circle",
                tone: .safe)
        }
        return DashboardStatusSlot(
            title: "Quota unavailable",
            detail: snapshot.errorMessage ?? "Wait for a complete Codex usage result.",
            symbol: "exclamationmark.triangle",
            tone: .error)
    }

    private static func observationDetail(_ observation: UsageObservationState) -> String {
        guard observation.observations.count >= 2,
              let previous = observation.observations.dropLast().last,
              let latest = observation.observations.last
        else {
            return "Changes appear after two successful checks in the same quota window."
        }

        let changes = [
            Self.windowChange(
                label: "Session",
                previous: previous.fingerprint.session,
                latest: latest.fingerprint.session),
            Self.windowChange(
                label: "Weekly",
                previous: previous.fingerprint.weekly,
                latest: latest.fingerprint.weekly),
        ].compactMap { $0 }

        if changes.isEmpty {
            return "No same-window quota change was recorded on the last successful check."
        }
        return changes.joined(separator: "  ")
    }

    private static func windowChange(
        label: String,
        previous: UsageQuotaFingerprint.Window,
        latest: UsageQuotaFingerprint.Window
    ) -> String? {
        guard previous.resetEpoch == latest.resetEpoch,
              previous.remainingBasisPoints >= 0,
              latest.remainingBasisPoints >= 0,
              previous.remainingBasisPoints != latest.remainingBasisPoints
        else { return nil }
        let old = Double(previous.remainingBasisPoints) / 100
        let new = Double(latest.remainingBasisPoints) / 100
        return "\(label) \(Int(old.rounded()))% -> \(Int(new.rounded()))%"
    }
}

struct TodayVsNormalPresentation: Equatable {
    static let minimumComparableDays = 3

    let todayText: String
    let normalText: String
    let deltaText: String
    let confidenceText: String
    let baselineTokens: Int?
    let isAvailable: Bool

    init(snapshot: LocalUsageAnalyticsSnapshot, now: Date) {
        let todayKey = LocalUsageLogScanner.dayFormatter.string(from: now)
        let todayTokens = snapshot.dailyHistory.first(where: { $0.date == todayKey })?.totalTokens
            ?? snapshot.todayTokens
        let prior = snapshot.dailyHistory
            .filter { $0.date < todayKey }
            .sorted { $0.date > $1.date }
            .prefix(7)
            .map(\.totalTokens)

        self.todayText = LocalUsageAnalyticsFormatter.tokenText(todayTokens)
        self.confidenceText = snapshot.dailyHistory.isEmpty || snapshot.isCostPartial
            ? "Estimated - Partial"
            : "Local exact"
        guard let todayTokens else {
            self.normalText = "unavailable"
            self.deltaText = "No dated activity for today"
            self.baselineTokens = nil
            self.isAvailable = false
            return
        }
        guard prior.count >= Self.minimumComparableDays else {
            self.normalText = "building"
            self.deltaText = "Building baseline (\(prior.count)/\(Self.minimumComparableDays) days)"
            self.baselineTokens = nil
            self.isAvailable = false
            return
        }

        let sorted = prior.sorted()
        let middle = sorted.count / 2
        let median: Int
        if sorted.count.isMultiple(of: 2) {
            median = Int((Double(sorted[middle - 1]) + Double(sorted[middle])) / 2)
        } else {
            median = sorted[middle]
        }
        self.baselineTokens = median
        self.normalText = LocalUsageAnalyticsFormatter.tokenText(median)
        self.isAvailable = true
        if median == 0 {
            self.deltaText = todayTokens == 0 ? "In line with normal" : "Normal baseline is zero"
        } else {
            let delta = (Double(todayTokens - median) / Double(median)) * 100
            if abs(delta) < 0.5 {
                self.deltaText = "In line with normal"
            } else {
                self.deltaText = "\(Int(abs(delta).rounded()))% \(delta > 0 ? "above" : "below") normal"
            }
        }
    }
}
