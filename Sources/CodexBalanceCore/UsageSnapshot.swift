import Foundation

public enum UsageSource: String, Codable, Sendable, CaseIterable {
    case loading = "loading"
    case oauth = "OAuth"
    case cliRPC = "CLI RPC"
    case localFallback = "local fallback"
    case fixture = "fixture"
    case error = "error"
}

public enum UsageWindowRole: String, Codable, Sendable {
    case session
    case weekly
    case unknown
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let resetAt: Date?
    public let windowSeconds: Int?

    public init(usedPercent: Double, resetAt: Date?, windowSeconds: Int?) {
        self.usedPercent = Self.clampPercent(usedPercent)
        self.resetAt = resetAt
        self.windowSeconds = windowSeconds
    }

    public var remainingPercent: Double {
        Self.clampPercent(100 - self.usedPercent)
    }

    public var role: UsageWindowRole {
        guard let windowSeconds else { return .unknown }
        if abs(windowSeconds - 18_000) <= 60 { return .session }
        if abs(windowSeconds - 604_800) <= 60 { return .weekly }
        return .unknown
    }

    static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

public struct UsageNamedWindow: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let window: UsageWindow
    public let detail: String?

    public init(id: String, title: String, window: UsageWindow, detail: String? = nil) {
        self.id = id
        self.title = title
        self.window = window
        self.detail = detail
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public static let maxUnknownResetCachedSessionAge: TimeInterval = 6 * 3_600

    public let sessionPercentRemaining: Double?
    public let weeklyPercentRemaining: Double?
    public let sessionResetAt: Date?
    public let weeklyResetAt: Date?
    public let extraWindows: [UsageNamedWindow]
    public let source: UsageSource
    public let updatedAt: Date
    public let isStale: Bool
    public let errorMessage: String?
    public let verifiedAt: Date?

    public init(
        sessionPercentRemaining: Double?,
        weeklyPercentRemaining: Double?,
        sessionResetAt: Date?,
        weeklyResetAt: Date?,
        extraWindows: [UsageNamedWindow] = [],
        source: UsageSource,
        updatedAt: Date,
        isStale: Bool = false,
        errorMessage: String? = nil,
        verifiedAt: Date? = nil)
    {
        self.sessionPercentRemaining = sessionPercentRemaining.map(UsageWindow.clampPercent)
        self.weeklyPercentRemaining = weeklyPercentRemaining.map(UsageWindow.clampPercent)
        self.sessionResetAt = sessionResetAt
        self.weeklyResetAt = weeklyResetAt
        self.extraWindows = extraWindows
        self.source = source
        self.updatedAt = updatedAt
        self.isStale = isStale
        self.errorMessage = errorMessage.map(Self.sanitized)
        self.verifiedAt = verifiedAt ?? (isStale ? nil : updatedAt)
    }

    public static func fromWindows(
        primary: UsageWindow?,
        secondary: UsageWindow?,
        extraWindows: [UsageNamedWindow] = [],
        source: UsageSource,
        updatedAt: Date = Date()) -> UsageSnapshot
    {
        let normalized = UsageWindowNormalizer.normalize(primary: primary, secondary: secondary)
        return UsageSnapshot(
            sessionPercentRemaining: normalized.session?.remainingPercent,
            weeklyPercentRemaining: normalized.weekly?.remainingPercent,
            sessionResetAt: normalized.session?.resetAt,
            weeklyResetAt: normalized.weekly?.resetAt,
            extraWindows: extraWindows,
            source: source,
            updatedAt: updatedAt)
    }

    public static func error(_ message: String, updatedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            sessionPercentRemaining: nil,
            weeklyPercentRemaining: nil,
            sessionResetAt: nil,
            weeklyResetAt: nil,
            source: .error,
            updatedAt: updatedAt,
            errorMessage: message)
    }

    public static func loading(updatedAt: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            sessionPercentRemaining: nil,
            weeklyPercentRemaining: nil,
            sessionResetAt: nil,
            weeklyResetAt: nil,
            source: .loading,
            updatedAt: updatedAt)
    }

    public func markedStale(errorMessage: String, updatedAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(
            sessionPercentRemaining: self.sessionPercentRemaining,
            weeklyPercentRemaining: self.weeklyPercentRemaining,
            sessionResetAt: self.sessionResetAt,
            weeklyResetAt: self.weeklyResetAt,
            extraWindows: self.extraWindows,
            source: self.source,
            updatedAt: updatedAt ?? self.updatedAt,
            isStale: true,
            errorMessage: errorMessage,
            verifiedAt: self.verifiedAt ?? self.updatedAt)
    }

    public var hasAnyQuota: Bool {
        self.sessionPercentRemaining != nil || self.weeklyPercentRemaining != nil
    }

    public var sourceLabel: String {
        if self.source == .error { return UsageSource.error.rawValue }
        return self.isStale ? "\(self.source.rawValue), stale" : self.source.rawValue
    }

    public func hasUsableCachedSessionPercent(now: Date = Date()) -> Bool {
        guard self.isStale, self.sessionPercentRemaining != nil else { return false }
        if let sessionResetAt {
            return sessionResetAt > now
        }
        if let weeklyResetAt, weeklyResetAt <= now {
            return false
        }
        return now.timeIntervalSince(self.verifiedAt ?? self.updatedAt)
            <= Self.maxUnknownResetCachedSessionAge
    }

    public func hasUsableCachedQuotaData(now: Date = Date()) -> Bool {
        guard self.hasAnyQuota else { return false }
        guard self.isStale else { return true }
        if self.hasUsableCachedSessionPercent(now: now) { return true }
        guard let weeklyResetAt else { return false }
        return weeklyResetAt > now
    }

    public func resetCountdown(now: Date = Date()) -> String {
        guard let resetAt = self.sessionResetAt ?? self.weeklyResetAt else {
            return "unknown"
        }
        return Self.countdown(to: resetAt, now: now)
    }

    public func sessionWindow() -> UsageWindow? {
        guard let sessionPercentRemaining else { return nil }
        return UsageWindow(
            usedPercent: 100 - sessionPercentRemaining,
            resetAt: self.sessionResetAt,
            windowSeconds: 18_000)
    }

    public func weeklyWindow() -> UsageWindow? {
        guard let weeklyPercentRemaining else { return nil }
        return UsageWindow(
            usedPercent: 100 - weeklyPercentRemaining,
            resetAt: self.weeklyResetAt,
            windowSeconds: 604_800)
    }

    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let remaining = max(0, Int(ceil(date.timeIntervalSince(now))))
        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "<1m"
    }

    public static func sanitized(_ message: String) -> String {
        var output = message
        let patterns = [
            #"(?im)^\s*authorization\s*:\s*bearer\s+[^\r\n]+"#,
            #"(?im)^\s*cookie\s*:\s*[^\r\n]+"#,
            #"(?im)^\s*x-api-key\s*:\s*[^\r\n]+"#,
            #"(?im)^\s*(?:openai|codex)[_-]?(?:api[_-]?)?key\s*=\s*[^\r\n]+"#,
            #"(?i)"(?:access|refresh|id)_token"\s*:\s*"[^"]+""#,
            #"(?i)"authorization"\s*:\s*"[^"]+""#,
            #"(?i)"cookie"\s*:\s*"[^"]+""#,
            #"(?i)\b(?:access_token|refresh_token|id_token|authorization|cookie)\s*=\s*[^\s&;\r\n]+"#,
            #"(?i)\bbearer\s+[^\s\r\n]+"#,
            #"sk-[A-Za-z0-9_\-]{12,}"#,
            #"~/(?:\.codex|Library)/(?:[^\s,;:]+)"#,
            #"/Users/[^\s,;:]+"#,
            #"/private/[^\s,;:]+"#,
            #"/var/[^\s,;:]+"#,
            #"/Volumes/[^\s,;:]+"#,
        ]
        for pattern in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression)
        }
        return output
    }
}

public struct UsageQuotaWindowPresentation: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let role: UsageWindowRole
        public let remainingPercent: Double?
        public let resetAt: Date?
        public let window: UsageWindow?

        fileprivate init(role: UsageWindowRole, snapshot: UsageSnapshot) {
            self.role = role
            switch role {
            case .session:
                self.remainingPercent = snapshot.sessionPercentRemaining
                self.resetAt = snapshot.sessionResetAt
                self.window = snapshot.sessionWindow()
            case .weekly:
                self.remainingPercent = snapshot.weeklyPercentRemaining
                self.resetAt = snapshot.weeklyResetAt
                self.window = snapshot.weeklyWindow()
            case .unknown:
                self.remainingPercent = nil
                self.resetAt = nil
                self.window = nil
            }
        }

        public var label: String {
            switch self.role {
            case .session: "Session"
            case .weekly: "Weekly"
            case .unknown: "Usage"
            }
        }
    }

    public let primaryRole: UsageWindowRole?
    public let rows: [Row]
}

public enum UsageQuotaWindowPresentationResolver {
    public static func resolve(snapshot: UsageSnapshot) -> UsageQuotaWindowPresentation {
        let roles: [UsageWindowRole]
        let primaryRole: UsageWindowRole?
        if snapshot.sessionPercentRemaining != nil {
            roles = snapshot.weeklyPercentRemaining == nil ? [.session] : [.session, .weekly]
            primaryRole = .session
        } else if snapshot.weeklyPercentRemaining != nil {
            roles = [.weekly]
            primaryRole = .weekly
        } else {
            roles = [.session, .weekly]
            primaryRole = nil
        }
        return UsageQuotaWindowPresentation(
            primaryRole: primaryRole,
            rows: roles.map { UsageQuotaWindowPresentation.Row(role: $0, snapshot: snapshot) })
    }
}

public enum UsageDisplayFormatter {
    public enum MenuBarWindowRole: String, Codable, Sendable {
        case session
        case weekly

        public var label: String {
            self == .session ? "Session" : "Weekly"
        }
    }

    public struct MenuBarRow: Equatable, Identifiable, Sendable {
        public let id: String
        public let windowRole: MenuBarWindowRole
        public let value: String
        public let marker: String?
        public let resetText: String?
        public let accessibilityText: String

        public var compactText: String {
            if let marker { return "\(marker) \(value)" }
            return value
        }
    }

    public struct MenuBarPresentation: Equatable, Sendable {
        public let rows: [MenuBarRow]
        public let isRefreshing: Bool
        public let accessibilityText: String
    }

    public static func menuBarPresentation(
        snapshot: UsageSnapshot,
        isRefreshing: Bool = false,
        now: Date = Date()) -> MenuBarPresentation
    {
        let resolved = UsageQuotaWindowPresentationResolver.resolve(snapshot: snapshot)
        let roles: [MenuBarWindowRole]
        if snapshot.sessionPercentRemaining != nil {
            roles = snapshot.weeklyPercentRemaining == nil ? [.session] : [.session, .weekly]
        } else if snapshot.weeklyPercentRemaining != nil {
            roles = [.weekly]
        } else {
            roles = [.session]
        }

        let rows = roles.map { role -> MenuBarRow in
            let display = self.menuBarValue(
                snapshot,
                role: role,
                isRefreshing: isRefreshing,
                now: now)
            let resetAt: Date?
            switch role {
            case .session: resetAt = snapshot.sessionResetAt
            case .weekly: resetAt = snapshot.weeklyResetAt
            }
            let resetText = resetAt.map { UsageSnapshot.countdown(to: $0, now: now) }
            let marker = roles.count > 1 && role == .weekly ? "W" : nil
            let resetAccessibility = resetText.map { ", resets in \($0)" } ?? ", reset time unavailable"
            return MenuBarRow(
                id: role.rawValue,
                windowRole: role,
                value: display.value,
                marker: marker,
                resetText: resetText,
                accessibilityText: "OpenAI Codex \(role.label) \(display.accessibilityValue)\(resetAccessibility)")
        }
        let text = rows.map(\.accessibilityText).joined(separator: ". ")
        let decision: String
        if snapshot.isStale { decision = " Cached quota; confirm before relying on it." }
        else if let remaining = snapshot.weeklyPercentRemaining ?? snapshot.sessionPercentRemaining,
                remaining <= 20 { decision = " Watch quota pace." }
        else { decision = " Can keep working." }
        let suffix = isRefreshing ? " Refreshing." : ""
        _ = resolved
        return MenuBarPresentation(
            rows: rows,
            isRefreshing: isRefreshing,
            accessibilityText: "\(text).\(decision)\(suffix)")
    }

    public static func menuBarCompactText(
        snapshot: UsageSnapshot,
        isRefreshing: Bool = false,
        now: Date = Date()) -> String
    {
        self.menuBarPresentation(snapshot: snapshot, isRefreshing: isRefreshing, now: now)
            .rows.map(\.compactText).joined(separator: " ")
    }

    public static func menuBarAccessibilityText(
        snapshot: UsageSnapshot,
        isRefreshing: Bool = false,
        now: Date = Date()) -> String
    {
        self.menuBarPresentation(snapshot: snapshot, isRefreshing: isRefreshing, now: now)
            .accessibilityText
    }

    public static func progressFraction(forRemainingPercent percent: Double?) -> Double? {
        guard let percent else { return nil }
        return UsageWindow.clampPercent(percent) / 100
    }

    private static func menuBarValue(
        _ snapshot: UsageSnapshot,
        role: MenuBarWindowRole,
        isRefreshing: Bool,
        now: Date) -> (value: String, accessibilityValue: String)
    {
        let percent: Double?
        let resetAt: Date?
        switch role {
        case .session:
            percent = snapshot.sessionPercentRemaining
            resetAt = snapshot.sessionResetAt
        case .weekly:
            percent = snapshot.weeklyPercentRemaining
            resetAt = snapshot.weeklyResetAt
        }

        if snapshot.isStale {
            if let percent,
               self.isWindowCacheUsable(snapshot: snapshot, role: role, resetAt: resetAt, now: now)
            {
                let value = Int(percent.rounded())
                return ("\(value)!", "\(value) percent remaining, cached stale value")
            }
            return ("--!", "stale value unavailable")
        }
        if let percent {
            let value = Int(percent.rounded())
            let freshness = isRefreshing ? "refreshing" : "fresh"
            return ("\(value)%", "\(value) percent remaining, \(freshness)")
        }
        if isRefreshing {
            return ("--", "loading")
        }
        if snapshot.errorMessage != nil {
            return ("--", "unavailable after an error")
        }
        return ("--", "unavailable")
    }

    private static func isWindowCacheUsable(
        snapshot: UsageSnapshot,
        role: MenuBarWindowRole,
        resetAt: Date?,
        now: Date) -> Bool
    {
        if let resetAt { return resetAt > now }
        switch role {
        case .session:
            if let weeklyResetAt = snapshot.weeklyResetAt, weeklyResetAt <= now {
                return false
            }
            return now.timeIntervalSince(snapshot.verifiedAt ?? snapshot.updatedAt)
                <= UsageSnapshot.maxUnknownResetCachedSessionAge
        case .weekly:
            return false
        }
    }
}

public enum UsageWindowNormalizer {
    public static func normalize(
        primary: UsageWindow?,
        secondary: UsageWindow?) -> (session: UsageWindow?, weekly: UsageWindow?)
    {
        let windows = [primary, secondary].compactMap { $0 }
        var session = windows.first { $0.role == .session }
        var weekly = windows.first { $0.role == .weekly }
        let unknowns = windows.filter { $0.role == .unknown }

        if session == nil, weekly == nil {
            session = unknowns.first
            weekly = unknowns.dropFirst().first
        } else if session == nil {
            session = unknowns.first
        } else if weekly == nil {
            weekly = unknowns.first
        }
        return (session, weekly)
    }
}
