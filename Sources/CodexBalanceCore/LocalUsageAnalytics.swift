import Combine
import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

public struct LocalUsageDailyBucket: Codable, Equatable, Identifiable, Sendable {
    public let date: String
    public let totalTokens: Int
    public let costUSD: Double?
    public let requestCount: Int

    public var id: String { self.date }

    public init(date: String, totalTokens: Int, costUSD: Double?, requestCount: Int) {
        self.date = date
        self.totalTokens = max(0, totalTokens)
        self.costUSD = costUSD
        self.requestCount = max(0, requestCount)
    }
}

public struct RecentCodexWork: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let observedAt: Date
    public let model: String
    public let tokenActivity: Int
    public let confidence: String

    public init(id: UUID = UUID(), observedAt: Date, model: String, tokenActivity: Int, confidence: String = "Partial") {
        self.id = id
        self.observedAt = observedAt
        self.model = model
        self.tokenActivity = max(0, tokenActivity)
        self.confidence = confidence
    }
}

public struct LocalUsageAnalyticsSnapshot: Codable, Equatable, Sendable {
    public let todayCostUSD: Double?
    public let todayTokens: Int?
    public let last30DaysCostUSD: Double?
    public let last30DaysTokens: Int?
    public let latestTokens: Int?
    public let topModel: String?
    public let dailyHistory: [LocalUsageDailyBucket]
    public let updatedAt: Date
    public let sourceLabel: String
    public let isStale: Bool
    public let errorMessage: String?
    public let isCostPartial: Bool
    public let estimateNote: String
    public let recentWork: [RecentCodexWork]

    public init(
        todayCostUSD: Double?,
        todayTokens: Int?,
        last30DaysCostUSD: Double?,
        last30DaysTokens: Int?,
        latestTokens: Int?,
        topModel: String?,
        dailyHistory: [LocalUsageDailyBucket],
        updatedAt: Date,
        sourceLabel: String = "Local Codex logs",
        isStale: Bool = false,
        errorMessage: String? = nil,
        isCostPartial: Bool = false,
        estimateNote: String = "Estimated from local Codex logs at API rates; may differ from your plan or bill.",
        recentWork: [RecentCodexWork] = [])
    {
        self.todayCostUSD = todayCostUSD
        self.todayTokens = todayTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.last30DaysTokens = last30DaysTokens
        self.latestTokens = latestTokens
        self.topModel = topModel
        self.dailyHistory = dailyHistory
        self.updatedAt = updatedAt
        self.sourceLabel = sourceLabel
        self.isStale = isStale
        self.errorMessage = errorMessage.map(UsageSnapshot.sanitized)
        self.isCostPartial = isCostPartial
        self.estimateNote = estimateNote
        self.recentWork = Array(recentWork.prefix(5))
    }

    public static func unavailable(
        message: String = "No local Codex usage analytics yet.",
        updatedAt: Date = Date()) -> LocalUsageAnalyticsSnapshot
    {
        LocalUsageAnalyticsSnapshot(
            todayCostUSD: nil,
            todayTokens: nil,
            last30DaysCostUSD: nil,
            last30DaysTokens: nil,
            latestTokens: nil,
            topModel: nil,
            dailyHistory: [],
            updatedAt: updatedAt,
            errorMessage: message,
            isCostPartial: true)
    }

    public func markedStale(errorMessage: String, updatedAt: Date = Date()) -> LocalUsageAnalyticsSnapshot {
        LocalUsageAnalyticsSnapshot(
            todayCostUSD: self.todayCostUSD,
            todayTokens: self.todayTokens,
            last30DaysCostUSD: self.last30DaysCostUSD,
            last30DaysTokens: self.last30DaysTokens,
            latestTokens: self.latestTokens,
            topModel: self.topModel,
            dailyHistory: self.dailyHistory,
            updatedAt: updatedAt,
            sourceLabel: self.sourceLabel,
            isStale: true,
            errorMessage: errorMessage,
            isCostPartial: self.isCostPartial,
            estimateNote: self.estimateNote,
            recentWork: self.recentWork)
    }

    public var hasAnyData: Bool {
        self.todayTokens != nil
            || self.last30DaysTokens != nil
            || self.latestTokens != nil
            || !self.dailyHistory.isEmpty
    }
}

public enum LocalUsageAnalyticsFormatter {
    public static func costText(_ value: Double?) -> String {
        guard let value else { return "N/A" }
        if value < 0.005 { return "<$0.01" }
        return String(format: "$%.2f", value)
    }

    public static func tokenText(_ value: Int?) -> String {
        guard let value else { return "unavailable" }
        return Self.integerFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func sourceText(_ snapshot: LocalUsageAnalyticsSnapshot) -> String {
        snapshot.isStale ? "\(snapshot.sourceLabel), stale" : snapshot.sourceLabel
    }

    public static func unavailableText(_ snapshot: LocalUsageAnalyticsSnapshot) -> String {
        if let message = snapshot.errorMessage, !message.isEmpty {
            return "\(message) Quota above is unaffected."
        }
        return "No local Codex logs yet. Quota above is unaffected."
    }

    public static func estimateShortNote(_ snapshot: LocalUsageAnalyticsSnapshot) -> String {
        if snapshot.hasAnyData,
           snapshot.todayCostUSD == nil,
           snapshot.last30DaysCostUSD == nil
        {
            return "Tokens from local logs; cost unavailable without usage breakdown."
        }
        return snapshot.isCostPartial
            ? "Estimated from local logs; cost may be partial."
            : "Estimated from local logs; not official billing."
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

public struct LocalUsageAnalyticsCache: Sendable {
    private let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CodexBalance/local-analytics-codex.json")
    }

    public func load() -> LocalUsageAnalyticsSnapshot? {
        guard let data = PrivateFileStore.read(at: self.url) else { return nil }
        return try? JSONDecoder().decode(LocalUsageAnalyticsSnapshot.self, from: data)
    }

    public func save(_ snapshot: LocalUsageAnalyticsSnapshot) {
        guard snapshot.hasAnyData,
              !snapshot.isStale,
              let data = try? JSONEncoder().encode(snapshot)
        else { return }
        try? PrivateFileStore.write(data, to: self.url)
    }
}

public protocol LocalUsageAnalyticsProviding: Sendable {
    func fetchAnalytics() async throws -> LocalUsageAnalyticsSnapshot
}

@MainActor
public final class LocalUsageAnalyticsStore: ObservableObject {
    @Published public private(set) var snapshot: LocalUsageAnalyticsSnapshot
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastSuccessfulRefreshAt: Date?
    @Published public private(set) var lastErrorMessage: String?

    private let provider: any LocalUsageAnalyticsProviding
    private let cache: LocalUsageAnalyticsCache

    public init(
        provider: any LocalUsageAnalyticsProviding,
        cache: LocalUsageAnalyticsCache = LocalUsageAnalyticsCache())
    {
        self.provider = provider
        self.cache = cache
        if let cached = cache.load() {
            self.snapshot = cached
            self.lastSuccessfulRefreshAt = cached.updatedAt
        } else {
            self.snapshot = .unavailable()
        }
    }

    @discardableResult
    public func refresh() async -> Bool {
        guard !self.isRefreshing else { return false }
        self.isRefreshing = true
        defer { self.isRefreshing = false }
        do {
            try Task.checkCancellation()
            let next = try await self.provider.fetchAnalytics()
            try Task.checkCancellation()
            self.snapshot = next
            if next.hasAnyData, next.errorMessage == nil, !next.isStale {
                self.lastSuccessfulRefreshAt = next.updatedAt
                self.lastErrorMessage = nil
                self.cache.save(next)
            } else if let errorMessage = next.errorMessage {
                self.lastErrorMessage = errorMessage
            }
            return true
        } catch {
            let message = UsageSnapshot.sanitized(error.localizedDescription)
            self.lastErrorMessage = message
            if self.snapshot.hasAnyData {
                self.snapshot = self.snapshot.markedStale(errorMessage: message)
            } else if let cached = self.cache.load(), cached.hasAnyData {
                self.snapshot = cached.markedStale(errorMessage: message)
                self.lastSuccessfulRefreshAt = cached.updatedAt
            } else {
                self.snapshot = .unavailable(message: message)
            }
            return false
        }
    }

    public func replaceSnapshotForTesting(_ snapshot: LocalUsageAnalyticsSnapshot) {
        self.snapshot = snapshot
        if snapshot.hasAnyData, snapshot.errorMessage == nil, !snapshot.isStale {
            self.lastSuccessfulRefreshAt = snapshot.updatedAt
            self.lastErrorMessage = nil
        } else {
            self.lastErrorMessage = snapshot.errorMessage
        }
    }
}

@MainActor
public final class LocalUsageAnalyticsScheduler: ObservableObject {
    @Published public private(set) var lastRefreshAt: Date?

    private let store: LocalUsageAnalyticsStore
    private let interval: TimeInterval
    private var timer: Timer?
    private var task: Task<Void, Never>?

    public init(store: LocalUsageAnalyticsStore, interval: TimeInterval = 5 * 60) {
        self.store = store
        self.interval = max(60, interval)
    }

    public func start() {
        self.refreshNow()
        self.scheduleNext()
    }

    public func stop() {
        self.timer?.invalidate()
        self.timer = nil
        self.task?.cancel()
        self.task = nil
    }

    public func refreshNow() {
        guard self.task == nil else { return }
        self.task = Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.store.refresh()
            self.lastRefreshAt = Date()
            self.task = nil
        }
    }

    public func refreshNowAndWait() async {
        if let task {
            await task.value
            return
        }
        self.refreshNow()
        await self.task?.value
    }

    private func scheduleNext() {
        self.timer?.invalidate()
        self.timer = Timer.scheduledTimer(withTimeInterval: self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }
}

public struct FixtureLocalUsageAnalyticsProvider: LocalUsageAnalyticsProviding, Sendable {
    public enum Mode: String, Sendable {
        case full
        case empty
        case error
    }

    private let mode: Mode
    private let now: @Sendable () -> Date

    public init(mode: Mode = .full, now: @escaping @Sendable () -> Date = Date.init) {
        self.mode = mode
        self.now = now
    }

    public func fetchAnalytics() async throws -> LocalUsageAnalyticsSnapshot {
        let now = self.now()
        switch self.mode {
        case .error:
            throw LocalUsageAnalyticsError.scanFailed("Synthetic analytics failure.")
        case .empty:
            return .unavailable(message: "No local Codex logs found.", updatedAt: now)
        case .full:
            let daily = Self.fixtureDaily(now: now)
            return LocalUsageAnalyticsSnapshot(
                todayCostUSD: daily.last?.costUSD,
                todayTokens: daily.last?.totalTokens,
                last30DaysCostUSD: daily.compactMap(\.costUSD).reduce(0, +),
                last30DaysTokens: daily.reduce(0) { $0 + $1.totalTokens },
                latestTokens: 18_420,
                topModel: "gpt-5.4-codex",
                dailyHistory: daily,
                updatedAt: now,
                sourceLabel: "Local Codex logs fixture")
        }
    }

    private static func fixtureDaily(now: Date) -> [LocalUsageDailyBucket] {
        let calendar = Calendar(identifier: .gregorian)
        return (0..<14).map { index in
            let date = calendar.date(byAdding: .day, value: -(13 - index), to: now) ?? now
            let wave = (index % 5) + 1
            let tokens = 18_000 + wave * 2_900
            return LocalUsageDailyBucket(
                date: LocalUsageLogScanner.dayFormatter.string(from: date),
                totalTokens: tokens,
                costUSD: Double(tokens) * 0.0000042,
                requestCount: 2 + wave)
        }
    }
}

public enum LocalUsageAnalyticsError: LocalizedError, Equatable, Sendable {
    case noLogsFound
    case scanFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noLogsFound:
            "No local Codex usage logs were found."
        case let .scanFailed(message):
            "Local Codex analytics scan failed: \(UsageSnapshot.sanitized(message))"
        }
    }
}

public struct CodexLocalLogAnalyticsProvider: LocalUsageAnalyticsProviding, Sendable {
    private let env: [String: String]
    private let codexHome: URL?
    private let now: @Sendable () -> Date
    private let options: LocalUsageLogScanner.Options
    private let index: LocalUsageIndex

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        codexHome: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        options: LocalUsageLogScanner.Options = LocalUsageLogScanner.Options(),
        index: LocalUsageIndex = LocalUsageIndex())
    {
        self.env = env
        self.codexHome = codexHome
        self.now = now
        self.options = options
        self.index = index
    }

    public func fetchAnalytics() async throws -> LocalUsageAnalyticsSnapshot {
        let now = self.now()
        let roots = Self.codexRoots(env: self.env, codexHome: self.codexHome)
        let databaseURL = Self.codexStateDatabaseURL(env: self.env, codexHome: self.codexHome)
        return try await Task.detached(priority: .utility) {
            do {
                let indexed = try self.index.refresh(roots: roots, now: now, options: self.options).snapshot
                if indexed.hasAnyData { return indexed }
                return try LocalUsageLogScanner.scanCodexThreadState(
                    databaseURL: databaseURL,
                    now: now,
                    options: self.options)
            } catch {
                return try LocalUsageLogScanner.scanCodexThreadState(
                    databaseURL: databaseURL,
                    now: now,
                    options: self.options)
            }
        }.value
    }

    public static func codexRoots(env: [String: String], codexHome: URL? = nil) -> [URL] {
        let home = Self.home(env: env, codexHome: codexHome)
        return [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    public static func codexStateDatabaseURL(env: [String: String], codexHome: URL? = nil) -> URL {
        if let override = CodexBalanceEnvironment.value("CODEX_BALANCE_CODEX_STATE_DB_PATH", in: env) {
            return URL(fileURLWithPath: override)
        }
        return Self.home(env: env, codexHome: codexHome).appendingPathComponent("state_5.sqlite")
    }

    private static func home(env: [String: String], codexHome: URL?) -> URL {
        codexHome
            ?? env["CODEX_HOME"].flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : URL(fileURLWithPath: $0)
            }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
    }
}

public enum LocalUsageLogScanner {
    public struct Options: Sendable {
        public var historyDays: Int
        public var maxFiles: Int
        public var maxLineBytes: Int

        public init(historyDays: Int = 30, maxFiles: Int = 5_000, maxLineBytes: Int = 512 * 1024) {
            self.historyDays = max(1, min(365, historyDays))
            self.maxFiles = max(1, maxFiles)
            self.maxLineBytes = max(1_024, maxLineBytes)
        }
    }

    struct Record: Codable, Sendable {
        let timestamp: Date
        let model: String
        let inputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        let outputTokens: Int
        let costUSD: Double?

        var totalTokens: Int {
            self.inputTokens + self.cacheReadTokens + self.cacheCreationTokens + self.outputTokens
        }
    }

    private enum UsageCounterKind {
        case incremental
        case cumulativeTotal
    }

    private struct UsageCandidate {
        let usage: [String: Any]
        let kind: UsageCounterKind
    }

    struct TokenTotals: Codable, Sendable {
        let input: Int
        let cacheRead: Int
        let cacheCreate: Int
        let output: Int

        var total: Int { self.input + self.cacheRead + self.cacheCreate + self.output }

        func delta(from previous: TokenTotals) -> TokenTotals {
            TokenTotals(
                input: max(0, self.input - previous.input),
                cacheRead: max(0, self.cacheRead - previous.cacheRead),
                cacheCreate: max(0, self.cacheCreate - previous.cacheCreate),
                output: max(0, self.output - previous.output))
        }
    }

    struct FileScanState: Codable, Sendable {
        var currentModel: String?
        var previousCumulative: TokenTotals?

        init(currentModel: String? = nil, previousCumulative: TokenTotals? = nil) {
            self.currentModel = currentModel
            self.previousCumulative = previousCumulative
        }
    }

    struct FileScanResult: Sendable {
        let records: [Record]
        let state: FileScanState
        let bytesRead: Int
    }

    public static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    public static func scanCodex(
        roots: [URL],
        now: Date,
        options: Options = Options()) throws -> LocalUsageAnalyticsSnapshot
    {
        let files = self.jsonlFiles(roots: roots, maxFiles: options.maxFiles)
        guard !files.isEmpty else { throw LocalUsageAnalyticsError.noLogsFound }
        var records: [Record] = []
        for file in files {
            try Task.checkCancellation()
            records.append(contentsOf: try self.records(fileURL: file, options: options))
        }
        return try self.snapshot(records: records, now: now, options: options)
    }

    public static func scanCodexThreadState(
        databaseURL: URL,
        now: Date,
        options: Options = Options()) throws -> LocalUsageAnalyticsSnapshot
    {
        #if canImport(SQLite3)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw LocalUsageAnalyticsError.noLogsFound
        }
        let calendar = Calendar.current
        let startDate = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -(options.historyDays - 1), to: now) ?? now)
        var db: OpaquePointer?
        let open = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard open == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw LocalUsageAnalyticsError.scanFailed("Thread database could not be opened read-only.")
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT updated_at, COALESCE(NULLIF(model, ''), 'unknown-codex-model'), tokens_used
        FROM threads
        WHERE model_provider = 'openai'
          AND tokens_used > 0
          AND updated_at >= ?
          AND updated_at <= ?
        ORDER BY updated_at DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw LocalUsageAnalyticsError.scanFailed("Thread database query is unavailable.")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(startDate.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(now.addingTimeInterval(60).timeIntervalSince1970))
        sqlite3_bind_int(statement, 3, Int32(options.maxFiles))

        var records: [Record] = []
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw LocalUsageAnalyticsError.scanFailed("Thread database read failed.")
            }
            let timestamp = sqlite3_column_int64(statement, 0)
            let tokens = max(0, Int(sqlite3_column_int64(statement, 2)))
            guard timestamp > 0, tokens > 0 else { continue }
            let model = sqlite3_column_text(statement, 1)
                .map { String(cString: $0) } ?? "unknown-codex-model"
            records.append(Record(
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)),
                model: EstimatedTokenPricing.normalizeModel(model),
                inputTokens: tokens,
                cacheReadTokens: 0,
                cacheCreationTokens: 0,
                outputTokens: 0,
                costUSD: nil))
        }
        // `tokens_used` is cumulative per thread, not a dated usage event.
        // It is useful evidence of recent activity, but must never be labelled
        // as Today/30d tokens or used to create a histogram.
        return LocalUsageAnalyticsSnapshot(
            todayCostUSD: nil,
            todayTokens: nil,
            last30DaysCostUSD: nil,
            last30DaysTokens: nil,
            latestTokens: nil,
            topModel: nil,
            dailyHistory: [],
            updatedAt: now,
            sourceLabel: "Codex thread state (recent activity)",
            isCostPartial: true,
            estimateNote: "Recent thread activity is partial. Cumulative thread tokens are not presented as dated usage or official billing.",
            recentWork: records
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(5)
                .map { RecentCodexWork(id: self.workID(for: $0), observedAt: $0.timestamp, model: $0.model, tokenActivity: $0.totalTokens, confidence: "Partial") })
        #else
        _ = databaseURL
        _ = now
        _ = options
        throw LocalUsageAnalyticsError.noLogsFound
        #endif
    }

    static func records(fileURL: URL, options: Options = Options()) throws -> [Record] {
        try self.scanFile(fileURL: fileURL, options: options).records
    }

    static func scanFile(
        fileURL: URL,
        startingAt offset: UInt64 = 0,
        state initialState: FileScanState = FileScanState(),
        options: Options = Options()) throws -> FileScanResult
    {
        var output: [Record] = []
        var state = initialState
        let bytesRead = try self.scanJSONLines(fileURL: fileURL, startingAt: offset, options: options) { object in
            let payload = object["payload"] as? [String: Any]
            if let model = self.model(from: object, payload: payload, fallback: state.currentModel) {
                state.currentModel = model
            }
            guard let timestamp = self.timestamp(from: object, payload: payload),
                  let candidate = self.usageCandidate(from: object, payload: payload)
            else { return }
            let raw = self.tokenTotals(from: candidate.usage)
            let totals: TokenTotals
            switch candidate.kind {
            case .incremental:
                totals = raw
            case .cumulativeTotal:
                if let previousTotal = state.previousCumulative {
                    totals = raw.delta(from: previousTotal)
                } else {
                    totals = TokenTotals(input: 0, cacheRead: 0, cacheCreate: 0, output: 0)
                }
                state.previousCumulative = raw
            }
            guard totals.total > 0 else { return }
            let model = self.model(from: object, payload: payload, fallback: state.currentModel)
                ?? "unknown-codex-model"
            output.append(Record(
                timestamp: timestamp,
                model: EstimatedTokenPricing.normalizeModel(model),
                inputTokens: totals.input,
                cacheReadTokens: totals.cacheRead,
                cacheCreationTokens: totals.cacheCreate,
                outputTokens: totals.output,
                costUSD: EstimatedTokenPricing.costUSD(
                    model: model,
                    inputTokens: totals.input,
                    cacheReadTokens: totals.cacheRead,
                    cacheCreationTokens: totals.cacheCreate,
                    outputTokens: totals.output)))
        }
        return FileScanResult(records: output, state: state, bytesRead: bytesRead)
    }

    static func snapshot(
        records: [Record],
        now: Date,
        options: Options) throws -> LocalUsageAnalyticsSnapshot
    {
        let calendar = Calendar.current
        let start = calendar.startOfDay(
            for: calendar.date(byAdding: .day, value: -(options.historyDays - 1), to: now) ?? now)
        let usable = self.deduplicated(records.filter { $0.timestamp >= start && $0.timestamp <= now.addingTimeInterval(60) })
        guard !usable.isEmpty else {
            return .unavailable(
                message: "No local Codex analytics rows found in the last \(options.historyDays)d.",
                updatedAt: now)
        }

        let todayKey = self.dayFormatter.string(from: now)
        var dayTokens: [String: Int] = [:]
        var dayCost: [String: Double] = [:]
        var dayRequests: [String: Int] = [:]
        var modelTokens: [String: Int] = [:]
        var latest = usable[0]
        var partial = false

        for record in usable {
            let day = self.dayFormatter.string(from: record.timestamp)
            dayTokens[day, default: 0] += record.totalTokens
            dayRequests[day, default: 0] += 1
            modelTokens[record.model, default: 0] += record.totalTokens
            if let costUSD = record.costUSD {
                dayCost[day, default: 0] += costUSD
            } else {
                partial = true
            }
            if record.timestamp >= latest.timestamp { latest = record }
        }

        let history = (0..<options.historyDays).map { index -> LocalUsageDailyBucket in
            let date = calendar.date(
                byAdding: .day,
                value: -(options.historyDays - 1 - index),
                to: now) ?? now
            let key = self.dayFormatter.string(from: date)
            return LocalUsageDailyBucket(
                date: key,
                totalTokens: dayTokens[key] ?? 0,
                costUSD: dayCost[key],
                requestCount: dayRequests[key] ?? 0)
        }
        let topModel = modelTokens.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
        let totalCost = history.compactMap(\.costUSD).reduce(0, +)
        return LocalUsageAnalyticsSnapshot(
            todayCostUSD: dayCost[todayKey],
            todayTokens: dayTokens[todayKey],
            last30DaysCostUSD: totalCost > 0 ? totalCost : nil,
            last30DaysTokens: history.reduce(0) { $0 + $1.totalTokens },
            latestTokens: latest.totalTokens,
            topModel: topModel,
            dailyHistory: history,
            updatedAt: now,
            isCostPartial: partial,
            recentWork: usable
                .sorted { $0.timestamp > $1.timestamp }
                .prefix(5)
                .map { RecentCodexWork(id: self.workID(for: $0), observedAt: $0.timestamp, model: $0.model, tokenActivity: $0.totalTokens, confidence: partial ? "Partial" : "Local exact") })
    }

    private static func workID(for record: Record) -> UUID {
        let material = "\(record.timestamp.timeIntervalSince1970)|\(record.model)|\(record.inputTokens)|\(record.cacheReadTokens)|\(record.cacheCreationTokens)|\(record.outputTokens)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in material.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let hex = String(format: "%016llx", hash)
        return UUID(uuidString: "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.prefix(4))-\(hex.prefix(12))") ?? UUID()
    }

    static func jsonlFiles(roots: [URL], maxFiles: Int) -> [URL] {
        var files: [(url: URL, modifiedAt: Date)] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }
            if isDirectory.boolValue {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
                else { continue }
                for case let url as URL in enumerator {
                    if url.pathExtension == "jsonl" {
                        let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        files.append((url, modifiedAt))
                    }
                }
            } else if root.pathExtension == "jsonl" {
                let modifiedAt = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                files.append((root, modifiedAt))
            }
        }
        return files
            .sorted { lhs, rhs in
                lhs.modifiedAt == rhs.modifiedAt ? lhs.url.path > rhs.url.path : lhs.modifiedAt > rhs.modifiedAt
            }
            .prefix(maxFiles)
            .map(\.url)
            .sorted { $0.path < $1.path }
    }

    private static func deduplicated(_ records: [Record]) -> [Record] {
        var seen: Set<String> = []
        return records.sorted { $0.timestamp < $1.timestamp }.filter { record in
            let key = "\(Int(record.timestamp.timeIntervalSince1970 * 1_000))|\(record.model)|\(record.inputTokens)|\(record.cacheReadTokens)|\(record.cacheCreationTokens)|\(record.outputTokens)"
            return seen.insert(key).inserted
        }
    }

    private static func scanJSONLines(
        fileURL: URL,
        startingAt offset: UInt64 = 0,
        options: Options,
        onObject: ([String: Any]) -> Void) throws -> Int
    {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        var bytesRead = 0
        var buffer = Data()
        var discardingOverlongLine = false
        while true {
            try Task.checkCancellation()
            var chunk = try autoreleasepool {
                try handle.read(upToCount: 64 * 1024) ?? Data()
            }
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            while !chunk.isEmpty {
                if discardingOverlongLine {
                    guard let newline = chunk.firstIndex(of: 0x0A) else { break }
                    chunk.removeSubrange(...newline)
                    discardingOverlongLine = false
                    continue
                }
                buffer.append(chunk)
                chunk.removeAll(keepingCapacity: false)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                self.consumeLine(Data(line.prefix(options.maxLineBytes)), onObject: onObject)
            }
                if buffer.count > options.maxLineBytes {
                    // Do not retain untrusted/oversized log lines. Continue
                    // reading only until their terminating newline.
                    buffer.removeAll(keepingCapacity: true)
                    discardingOverlongLine = true
                }
            }
        }
        if !buffer.isEmpty && !discardingOverlongLine {
            self.consumeLine(Data(buffer.prefix(options.maxLineBytes)), onObject: onObject)
        }
        return bytesRead
    }

    private static func consumeLine(_ line: Data, onObject: ([String: Any]) -> Void) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return }
        onObject(object)
    }

    private static func usageCandidate(
        from object: [String: Any],
        payload: [String: Any]?) -> UsageCandidate?
    {
        if let usage = self.usageDictionary(from: object, payload: payload) {
            return UsageCandidate(usage: usage, kind: .incremental)
        }
        let info = payload?["info"] as? [String: Any] ?? object["info"] as? [String: Any]
        if let usage = info?["last_token_usage"] as? [String: Any] {
            return UsageCandidate(usage: usage, kind: .incremental)
        }
        if let usage = info?["total_token_usage"] as? [String: Any] {
            return UsageCandidate(usage: usage, kind: .cumulativeTotal)
        }
        return nil
    }

    private static func usageDictionary(
        from object: [String: Any],
        payload: [String: Any]?) -> [String: Any]?
    {
        if let usage = object["usage"] as? [String: Any] { return usage }
        if let usage = payload?["usage"] as? [String: Any] { return usage }
        if let usage = (payload?["info"] as? [String: Any])?["usage"] as? [String: Any] {
            return usage
        }
        if let usage = object["token_usage"] as? [String: Any] { return usage }
        if let usage = payload?["token_usage"] as? [String: Any] { return usage }
        return nil
    }

    private static func tokenTotals(from usage: [String: Any]) -> TokenTotals {
        TokenTotals(
            input: self.intValue(usage["input_tokens"] ?? usage["input"]),
            cacheRead: self.intValue(
                usage["cached_input_tokens"] ?? usage["cache_read_input_tokens"] ?? usage["cache_read"]),
            cacheCreate: self.intValue(
                usage["cache_creation_input_tokens"] ?? usage["cache_creation"]),
            output: self.intValue(usage["output_tokens"] ?? usage["output"])
                + self.intValue(usage["reasoning_output_tokens"] ?? usage["reasoning_output"]))
    }

    private static func model(
        from object: [String: Any],
        payload: [String: Any]?,
        fallback: String?) -> String?
    {
        let info = payload?["info"] as? [String: Any] ?? object["info"] as? [String: Any]
        let collaboration = payload?["collaboration_mode"] as? [String: Any]
        let settings = collaboration?["settings"] as? [String: Any]
        return self.stringValue(info?["model"])
            ?? self.stringValue(info?["model_name"])
            ?? self.stringValue(payload?["model"])
            ?? self.stringValue(object["model"])
            ?? self.stringValue(settings?["model"])
            ?? fallback
    }

    private static func timestamp(
        from object: [String: Any],
        payload: [String: Any]?) -> Date?
    {
        guard let raw = self.stringValue(object["timestamp"])
            ?? self.stringValue(object["time"])
            ?? self.stringValue(payload?["timestamp"])
            ?? self.stringValue(payload?["time"])
        else { return nil }
        if let unix = Double(raw), unix > 1_000_000_000 {
            return Date(timeIntervalSince1970: unix > 9_999_999_999 ? unix / 1_000 : unix)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int {
        if let value = value as? Int { return max(0, value) }
        if let value = value as? NSNumber { return max(0, value.intValue) }
        if let value = value as? String, let parsed = Int(value) { return max(0, parsed) }
        return 0
    }
}

public enum EstimatedTokenPricing {
    struct Price {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheCreate: Double?
    }

    public static func costUSD(
        model: String,
        inputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int,
        outputTokens: Int) -> Double?
    {
        guard let price = self.price(model: model) else { return nil }
        return Double(inputTokens) * price.input
            + Double(outputTokens) * price.output
            + Double(cacheReadTokens) * (price.cacheRead ?? price.input)
            + Double(cacheCreationTokens) * (price.cacheCreate ?? price.input)
    }

    static func normalizeModel(_ model: String) -> String {
        model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func price(model: String) -> Price? {
        let normalized = self.normalizeModel(model)
        if normalized.contains("mini") {
            return Price(input: 0.25e-6, output: 2e-6, cacheRead: 0.025e-6, cacheCreate: nil)
        }
        if normalized.contains("gpt-5.4") {
            return Price(input: 2.5e-6, output: 15e-6, cacheRead: 0.25e-6, cacheCreate: nil)
        }
        if normalized.contains("gpt-5.3") || normalized.contains("gpt-5.2") {
            return Price(input: 1.75e-6, output: 14e-6, cacheRead: 0.175e-6, cacheCreate: nil)
        }
        if normalized == "gpt-5" {
            return Price(input: 1.25e-6, output: 10e-6, cacheRead: 0.125e-6, cacheCreate: nil)
        }
        return nil
    }
}
