import Foundation

/// A typed result for one provider attempt. It deliberately contains no
/// response payload, credential material, path, or account identity.
public enum CodexProviderOutcome: Codable, Equatable, Sendable {
    case success
    case authenticationRequired
    case rateLimited(retryAfter: TimeInterval?)
    case transient
    case invalidData
    case cancelled

    private enum CodingKeys: String, CodingKey { case kind, retryAfter }
    private enum Kind: String, Codable { case success, authenticationRequired, rateLimited, transient, invalidData, cancelled }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .success: self = .success
        case .authenticationRequired: self = .authenticationRequired
        case .rateLimited: self = .rateLimited(retryAfter: try container.decodeIfPresent(TimeInterval.self, forKey: .retryAfter))
        case .transient: self = .transient
        case .invalidData: self = .invalidData
        case .cancelled: self = .cancelled
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success: try container.encode(Kind.success, forKey: .kind)
        case .authenticationRequired: try container.encode(Kind.authenticationRequired, forKey: .kind)
        case let .rateLimited(retryAfter):
            try container.encode(Kind.rateLimited, forKey: .kind)
            try container.encodeIfPresent(retryAfter, forKey: .retryAfter)
        case .transient: try container.encode(Kind.transient, forKey: .kind)
        case .invalidData: try container.encode(Kind.invalidData, forKey: .kind)
        case .cancelled: try container.encode(Kind.cancelled, forKey: .kind)
        }
    }
}

public struct CodexProviderAttempt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let source: UsageSource
    public let attemptedAt: Date
    public let outcome: CodexProviderOutcome

    public init(id: UUID = UUID(), source: UsageSource, attemptedAt: Date, outcome: CodexProviderOutcome) {
        self.id = id
        self.source = source
        self.attemptedAt = attemptedAt
        self.outcome = outcome
    }
}

/// Stable quota-only comparison value. Fetch time, source, stale/error state
/// and diagnostics are intentionally excluded so equivalent checks stay equal.
public struct UsageQuotaFingerprint: Codable, Equatable, Hashable, Sendable {
    public struct Window: Codable, Equatable, Hashable, Sendable {
        public let role: UsageWindowRole
        public let remainingBasisPoints: Int
        public let resetEpoch: Int?

        public init(role: UsageWindowRole, remaining: Double?, resetAt: Date?) {
            self.role = role
            self.remainingBasisPoints = Int(((remaining ?? -1) * 100).rounded())
            self.resetEpoch = resetAt.map { Int($0.timeIntervalSince1970.rounded()) }
        }
    }

    public let session: Window
    public let weekly: Window
    public let extras: [Window]

    public init(snapshot: UsageSnapshot) {
        self.session = Window(role: .session, remaining: snapshot.sessionPercentRemaining, resetAt: snapshot.sessionResetAt)
        self.weekly = Window(role: .weekly, remaining: snapshot.weeklyPercentRemaining, resetAt: snapshot.weeklyResetAt)
        self.extras = snapshot.extraWindows
            .map { Window(role: $0.window.role, remaining: $0.window.remainingPercent, resetAt: $0.window.resetAt) }
            .sorted { ($0.role.rawValue, $0.resetEpoch ?? -1, $0.remainingBasisPoints) < ($1.role.rawValue, $1.resetEpoch ?? -1, $1.remainingBasisPoints) }
    }
}

public struct UsageObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let observedAt: Date
    public let source: UsageSource
    public let fingerprint: UsageQuotaFingerprint

    public init(id: UUID = UUID(), observedAt: Date, source: UsageSource, fingerprint: UsageQuotaFingerprint) {
        self.id = id
        self.observedAt = observedAt
        self.source = source
        self.fingerprint = fingerprint
    }
}

public struct UsageObservationState: Codable, Equatable, Sendable {
    public private(set) var lastAttemptAt: Date?
    public private(set) var lastCheckedAt: Date?
    public private(set) var lastChangedAt: Date?
    public private(set) var lastVerifiedAt: Date?
    public private(set) var selectedSource: UsageSource?
    public private(set) var attempts: [CodexProviderAttempt]
    public private(set) var observations: [UsageObservation]

    public init(
        lastAttemptAt: Date? = nil,
        lastCheckedAt: Date? = nil,
        lastChangedAt: Date? = nil,
        lastVerifiedAt: Date? = nil,
        selectedSource: UsageSource? = nil,
        attempts: [CodexProviderAttempt] = [],
        observations: [UsageObservation] = [])
    {
        self.lastAttemptAt = lastAttemptAt
        self.lastCheckedAt = lastCheckedAt
        self.lastChangedAt = lastChangedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.selectedSource = selectedSource
        self.attempts = attempts
        self.observations = observations
    }

    public mutating func recordAttempt(_ attempt: CodexProviderAttempt, now: Date = Date()) {
        self.lastAttemptAt = attempt.attemptedAt
        self.attempts.append(attempt)
        self.attempts = self.attempts.filter { now.timeIntervalSince($0.attemptedAt) <= 30 * 86_400 }
    }

    /// Returns true only for an actual semantic change within the same reset epoch.
    @discardableResult
    public mutating func recordVerified(_ snapshot: UsageSnapshot, at date: Date = Date()) -> Bool {
        let next = UsageObservation(observedAt: date, source: snapshot.source, fingerprint: UsageQuotaFingerprint(snapshot: snapshot))
        self.lastCheckedAt = date
        self.lastVerifiedAt = date
        self.selectedSource = snapshot.source
        guard let previous = self.observations.last else {
            self.observations.append(next)
            self.trim(now: date)
            return false
        }
        let sameEpoch = previous.fingerprint.session.resetEpoch == next.fingerprint.session.resetEpoch
            && previous.fingerprint.weekly.resetEpoch == next.fingerprint.weekly.resetEpoch
        let changed = sameEpoch && previous.fingerprint != next.fingerprint
        if changed { self.lastChangedAt = date }
        self.observations.append(next)
        self.trim(now: date)
        return changed
    }

    public var latestFingerprint: UsageQuotaFingerprint? { self.observations.last?.fingerprint }

    private mutating func trim(now: Date) {
        self.observations = self.observations.filter { now.timeIntervalSince($0.observedAt) <= 30 * 86_400 }
    }
}

public enum CodexProviderOutcomeClassifier {
    public static func classify(_ error: Error) -> CodexProviderOutcome {
        if error is CancellationError { return .cancelled }
        if let providerError = error as? CodexUsageProviderError {
            switch providerError {
            case .authenticationRequired: return .authenticationRequired
            case let .rateLimited(retryAfter): return .rateLimited(retryAfter: retryAfter)
            case .invalidResponse: return .invalidData
            default: break
            }
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("401") || message.contains("403") || message.contains("unauthorized") || message.contains("forbidden") {
            return .authenticationRequired
        }
        if message.contains("429") || message.contains("rate limit") { return .rateLimited(retryAfter: nil) }
        if message.contains("invalid") || message.contains("decode") || message.contains("missing result") { return .invalidData }
        return .transient
    }
}
