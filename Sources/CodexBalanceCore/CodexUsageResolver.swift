import Foundation

public struct CodexUsageResolution: Sendable {
    public let snapshot: UsageSnapshot
    public let attempts: [CodexProviderAttempt]

    public init(snapshot: UsageSnapshot, attempts: [CodexProviderAttempt]) {
        self.snapshot = snapshot
        self.attempts = attempts
    }
}

public protocol CodexUsageResolving: Sendable {
    func resolveUsage() async throws -> CodexUsageResolution
}

public struct SingleCodexUsageResolver: CodexUsageResolving, Sendable {
    private let provider: any CodexUsageProviding

    public init(provider: any CodexUsageProviding) { self.provider = provider }

    public func resolveUsage() async throws -> CodexUsageResolution {
        let at = Date()
        do {
            let snapshot = try await self.provider.fetchUsage()
            return CodexUsageResolution(
                snapshot: snapshot,
                attempts: [CodexProviderAttempt(source: snapshot.source, attemptedAt: at, outcome: .success)])
        } catch {
            throw error
        }
    }
}

/// Owns source-local cooldowns. It preserves the established first-complete
/// cascade and never combines quota windows from separate providers.
public actor CodexUsageResolver: CodexUsageResolving, CodexUsageProviding {
    public struct Source: Sendable {
        public let kind: UsageSource
        public let provider: any CodexUsageProviding

        public init(kind: UsageSource, provider: any CodexUsageProviding) {
            self.kind = kind
            self.provider = provider
        }
    }

    private let sources: [Source]
    private var cooldowns: [UsageSource: Date] = [:]
    private var rateLimitFailures: [UsageSource: Int] = [:]
    private let now: @Sendable () -> Date

    public init(sources: [Source], now: @escaping @Sendable () -> Date = Date.init) {
        self.sources = sources
        self.now = now
    }

    public func resolveUsage() async throws -> CodexUsageResolution {
        var attempts: [CodexProviderAttempt] = []
        var failures: [String] = []
        for source in self.sources {
            let attemptedAt = self.now()
            if let cooldown = self.cooldowns[source.kind], cooldown > attemptedAt {
                attempts.append(CodexProviderAttempt(source: source.kind, attemptedAt: attemptedAt, outcome: .rateLimited(retryAfter: cooldown.timeIntervalSince(attemptedAt))))
                continue
            }
            do {
                let snapshot = try await source.provider.fetchUsage()
                guard snapshot.hasAnyQuota else { throw CodexUsageProviderError.noUsageWindows }
                self.rateLimitFailures[source.kind] = 0
                attempts.append(CodexProviderAttempt(source: source.kind, attemptedAt: attemptedAt, outcome: .success))
                return CodexUsageResolution(snapshot: snapshot, attempts: attempts)
            } catch is CancellationError {
                attempts.append(CodexProviderAttempt(source: source.kind, attemptedAt: attemptedAt, outcome: .cancelled))
                throw CancellationError()
            } catch {
                let outcome = CodexProviderOutcomeClassifier.classify(error)
                attempts.append(CodexProviderAttempt(source: source.kind, attemptedAt: attemptedAt, outcome: outcome))
                self.applyCooldown(for: source.kind, outcome: outcome, now: attemptedAt)
                failures.append(error.localizedDescription)
            }
        }
        throw CodexUsageProviderError.allSourcesFailed(failures)
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        try await self.resolveUsage().snapshot
    }

    private func applyCooldown(for source: UsageSource, outcome: CodexProviderOutcome, now: Date) {
        let interval: TimeInterval?
        switch outcome {
        case .authenticationRequired: interval = 15 * 60
        case let .rateLimited(retryAfter):
            let count = (self.rateLimitFailures[source] ?? 0) + 1
            self.rateLimitFailures[source] = count
            interval = min(15 * 60, retryAfter ?? (60 * pow(2, Double(min(count - 1, 4)))))
        case .transient: interval = 30
        case .invalidData: interval = 60
        case .success, .cancelled: interval = nil
        }
        if let interval { self.cooldowns[source] = now.addingTimeInterval(interval) }
    }
}
