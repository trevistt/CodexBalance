import Combine
import Foundation

public struct UsageSnapshotCache: Sendable {
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CodexBalance/last-codex-snapshot.json")
    }

    public func load() -> UsageSnapshot? {
        guard let data = PrivateFileStore.read(at: self.url) else { return nil }
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    public func save(_ snapshot: UsageSnapshot) {
        guard snapshot.hasAnyQuota,
              !snapshot.isStale,
              snapshot.errorMessage == nil,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        try? PrivateFileStore.write(data, to: self.url)
    }
}

public struct UsageObservationCache: Sendable {
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CodexBalance/codex-observations-v1.json")
    }

    public func load() -> UsageObservationState? {
        guard let data = PrivateFileStore.read(at: self.url) else { return nil }
        return try? JSONDecoder().decode(UsageObservationState.self, from: data)
    }

    public func save(_ state: UsageObservationState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? PrivateFileStore.write(data, to: self.url)
    }
}

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var snapshot: UsageSnapshot
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastSuccessfulRefreshAt: Date?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var observationState: UsageObservationState
    @Published public private(set) var lastQuotaChangedAt: Date?

    private let resolver: any CodexUsageResolving
    private let cache: UsageSnapshotCache
    private let observationCache: UsageObservationCache
    private var durableWriteTimes: [Date] = []

    public init(
        provider: any CodexUsageProviding,
        cache: UsageSnapshotCache = UsageSnapshotCache(),
        observationCache: UsageObservationCache = UsageObservationCache())
    {
        self.resolver = SingleCodexUsageResolver(provider: provider)
        self.cache = cache
        self.observationCache = observationCache
        let loadedObservationState = observationCache.load() ?? UsageObservationState()
        self.observationState = loadedObservationState
        self.lastQuotaChangedAt = loadedObservationState.lastChangedAt
        if let cached = cache.load() {
            self.snapshot = cached.markedStale(errorMessage: "Showing the last saved Codex usage until refresh completes.")
            self.lastSuccessfulRefreshAt = cached.verifiedAt ?? cached.updatedAt
        } else {
            self.snapshot = UsageSnapshot.loading()
        }
    }

    public init(
        resolver: any CodexUsageResolving,
        cache: UsageSnapshotCache = UsageSnapshotCache(),
        observationCache: UsageObservationCache = UsageObservationCache())
    {
        self.resolver = resolver
        self.cache = cache
        self.observationCache = observationCache
        let loadedObservationState = observationCache.load() ?? UsageObservationState()
        self.observationState = loadedObservationState
        self.lastQuotaChangedAt = loadedObservationState.lastChangedAt
        if let cached = cache.load() {
            self.snapshot = cached.markedStale(errorMessage: "Showing the last saved Codex usage until refresh completes.")
            self.lastSuccessfulRefreshAt = cached.verifiedAt ?? cached.updatedAt
        } else {
            self.snapshot = UsageSnapshot.loading()
        }
    }

    @discardableResult
    public func beginRefreshing() -> Bool {
        guard !self.isRefreshing else { return false }
        self.isRefreshing = true
        return true
    }

    @discardableResult
    public func refresh(alreadyMarkedRefreshing: Bool = false) async -> Bool {
        guard alreadyMarkedRefreshing || self.beginRefreshing() else { return false }
        defer { self.isRefreshing = false }

        do {
            try Task.checkCancellation()
            let resolution = try await self.resolver.resolveUsage()
            let next = resolution.snapshot
            try Task.checkCancellation()
            guard next.hasAnyQuota else {
                throw CodexUsageProviderError.noUsageWindows
            }
            self.snapshot = next
            self.lastSuccessfulRefreshAt = next.verifiedAt ?? next.updatedAt
            self.lastErrorMessage = nil
            let verifiedAt = next.verifiedAt ?? next.updatedAt
            for attempt in resolution.attempts { self.observationState.recordAttempt(attempt, now: verifiedAt) }
            let changed = self.observationState.recordVerified(next, at: verifiedAt)
            self.lastQuotaChangedAt = self.observationState.lastChangedAt
            let shouldPersist = changed || self.observationState.observations.count == 1
            if shouldPersist, self.canWriteSnapshot(at: verifiedAt) {
                self.observationCache.save(self.observationState)
                self.cache.save(next)
            }
            return true
        } catch is CancellationError {
            self.recordFailure(.cancelled, at: Date())
            self.applyFailure("Codex refresh was cancelled.")
            return false
        } catch {
            self.recordFailure(CodexProviderOutcomeClassifier.classify(error), at: Date())
            self.applyFailure(error.localizedDescription)
            return false
        }
    }

    public func replaceSnapshotForTesting(_ snapshot: UsageSnapshot) {
        self.snapshot = snapshot
        if snapshot.hasAnyQuota, !snapshot.isStale, snapshot.errorMessage == nil {
            self.lastSuccessfulRefreshAt = snapshot.verifiedAt ?? snapshot.updatedAt
            self.lastErrorMessage = nil
        } else if let errorMessage = snapshot.errorMessage {
            self.lastErrorMessage = UsageSnapshot.sanitized(errorMessage)
        }
    }

    public func replaceObservationStateForTesting(_ state: UsageObservationState) {
        self.observationState = state
        self.lastQuotaChangedAt = state.lastChangedAt
    }

    public func setRefreshingForTesting(_ refreshing: Bool) {
        self.isRefreshing = refreshing
    }

    private func applyFailure(_ rawMessage: String) {
        let message = UsageSnapshot.sanitized(rawMessage)
        self.lastErrorMessage = message
        if self.snapshot.hasAnyQuota {
            self.snapshot = self.snapshot.markedStale(errorMessage: message)
            return
        }
        if let cached = self.cache.load(), cached.hasAnyQuota {
            self.snapshot = cached.markedStale(errorMessage: message)
            self.lastSuccessfulRefreshAt = cached.verifiedAt ?? cached.updatedAt
            return
        }
        self.snapshot = UsageSnapshot.error(message)
    }

    private func recordFailure(_ outcome: CodexProviderOutcome, at date: Date) {
        self.observationState.recordAttempt(CodexProviderAttempt(source: .error, attemptedAt: date, outcome: outcome), now: date)
    }

    private func canWriteSnapshot(at date: Date) -> Bool {
        self.durableWriteTimes = self.durableWriteTimes.filter { date.timeIntervalSince($0) < 60 }
        guard self.durableWriteTimes.count < 2 else { return false }
        self.durableWriteTimes.append(date)
        return true
    }
}
