import Foundation
import CodexBalanceCore
import Testing

struct UsageCoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func sessionAndWeeklyPresentation() {
        let snapshot = self.snapshot(session: 35, weekly: 95)
        let presentation = UsageDisplayFormatter.menuBarPresentation(snapshot: snapshot, now: self.now)
        #expect(presentation.rows.count == 2)
        #expect(presentation.rows[0].value == "35%")
        #expect(presentation.rows[1].value == "95%")
        #expect(presentation.rows[1].marker == "W")
        #expect(presentation.rows[0].resetText == "2h 0m")
        #expect(presentation.accessibilityText.contains("OpenAI Codex Session"))
    }

    @Test
    func weeklyOnlyNeverSynthesizesSession() {
        let weekly = UsageWindow(
            usedPercent: 57,
            resetAt: self.now.addingTimeInterval(86_400),
            windowSeconds: 604_800)
        let snapshot = UsageSnapshot.fromWindows(
            primary: weekly,
            secondary: nil,
            source: .fixture,
            updatedAt: self.now)
        #expect(snapshot.sessionPercentRemaining == nil)
        #expect(snapshot.weeklyPercentRemaining == 43)
        let rows = UsageDisplayFormatter.menuBarPresentation(snapshot: snapshot, now: self.now).rows
        #expect(rows.count == 1)
        #expect(rows[0].windowRole == .weekly)
        #expect(rows[0].marker == nil)
        #expect(rows[0].resetText == "1d 0h")
    }

    @Test
    func staleAndUnavailableTruth() {
        let stale = self.snapshot(session: 89, weekly: 82)
            .markedStale(errorMessage: "Temporary refresh failure.")
        let staleRows = UsageDisplayFormatter.menuBarPresentation(snapshot: stale, now: self.now).rows
        #expect(staleRows[0].value == "89!")
        #expect(staleRows[1].value == "82!")

        let expiredRows = UsageDisplayFormatter.menuBarPresentation(
            snapshot: stale,
            now: self.now.addingTimeInterval(8 * 86_400)).rows
        #expect(expiredRows.allSatisfy { $0.value == "--!" })

        let hardError = UsageDisplayFormatter.menuBarPresentation(
            snapshot: .error("Unavailable.", updatedAt: self.now),
            now: self.now)
        #expect(hardError.rows.first?.value == "--")
    }

    @Test
    func initialLoadingIsNeutral() {
        let loading = UsageSnapshot.loading(updatedAt: self.now)
        let decision = UsageDecisionEngine.make(
            snapshot: loading,
            observation: UsageObservationState(),
            now: self.now)
        #expect(loading.errorMessage == nil)
        #expect(decision.headline == "Checking Codex quota")
        #expect(!decision.isCaution)
        let presentation = UsageDisplayFormatter.menuBarPresentation(
            snapshot: loading,
            isRefreshing: true,
            now: self.now)
        #expect(presentation.rows.first?.value == "--")
        #expect(presentation.accessibilityText.contains("loading"))
    }

    @Test
    func retryAfterSupportsDeltaAndHTTPDate() {
        let parser = OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.parseRetryAfter
        #expect(parser("42", self.now) == 42)
        #expect(parser("Fri, 15 Jan 2027 08:01:00 GMT", self.now) == 60)
        #expect(parser("Fri, 15 Jan 2027 07:59:00 GMT", self.now) == 0)
        #expect(parser("malformed", self.now) == nil)
    }

    @Test
    func paceReserveDeficitAndCountdown() {
        let reserve = UsagePace(
            window: UsageWindow(
                usedPercent: 20,
                resetAt: self.now.addingTimeInterval(9_000),
                windowSeconds: 18_000),
            now: self.now)
        #expect(reserve != nil)
        #expect(reserve?.lastsUntilReset == true)
        if case let .reserve(value) = reserve?.balance {
            #expect(Int(value.rounded()) == 30)
        } else {
            Issue.record("Expected reserve")
        }

        let deficit = UsagePace(
            window: UsageWindow(
                usedPercent: 80,
                resetAt: self.now.addingTimeInterval(9_000),
                windowSeconds: 18_000),
            now: self.now)
        #expect(deficit?.lastsUntilReset == false)
        #expect(UsagePaceFormatter.projectionText(deficit!, now: self.now).hasPrefix("Runs out in"))
        #expect(UsageSnapshot.countdown(to: self.now.addingTimeInterval(60.1), now: self.now) == "1m")
        #expect(UsageSnapshot.countdown(to: self.now.addingTimeInterval(0.1), now: self.now) == "<1m")
    }

    @Test
    func oauthMappingKeepsExtraWindows() throws {
        let data = Data("""
        {
          "rate_limit": {
            "primary_window": {"used_percent": 25, "reset_at": 1800010000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 60, "reset_at": 1800300000, "limit_window_seconds": 604800}
          },
          "additional_rate_limits": [{
            "limit_name": "Codex Spark",
            "rate_limit": {
              "primary_window": {"used_percent": 10, "reset_at": 1800012000, "limit_window_seconds": 18000},
              "secondary_window": {"used_percent": 20, "reset_at": 1800400000, "limit_window_seconds": 604800}
            }
          }]
        }
        """.utf8)
        let snapshot = try OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.mapUsageResponse(
            data,
            source: .oauth,
            updatedAt: self.now)
        #expect(snapshot.sessionPercentRemaining == 75)
        #expect(snapshot.weeklyPercentRemaining == 40)
        #expect(snapshot.extraWindows.map(\.id) == ["codex-spark", "codex-spark-weekly"])
    }

    @Test
    func oauthUsesOnlyChatGPTOAuthToken() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-balance-oauth-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let authURL = root.appendingPathComponent("auth.json")
        let env = ["CODEX_BALANCE_AUTH_PATH": authURL.path]

        try Data(#"{"OPENAI_API_KEY":"test-api-only"}"#.utf8).write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        let apiOnlyClient = RecordingUsageHTTPClient(responseData: Self.oauthResponseData)
        let apiOnlyProvider = OAuthCodexUsageProvider(env: env, httpClient: apiOnlyClient, now: { self.now })
        do {
            _ = try await apiOnlyProvider.fetchUsage()
            Issue.record("API-key-only auth must fail the OAuth provider closed")
        } catch let error as CodexUsageProviderError {
            #expect(error == .missingCredentials)
        }
        #expect(await apiOnlyClient.calls() == 0)

        try Data(#"{"tokens":{"accessToken":"test-camel-only"}}"#.utf8)
            .write(to: authURL, options: .atomic)
        let camelOnlyClient = RecordingUsageHTTPClient(responseData: Self.oauthResponseData)
        let camelOnlyProvider = OAuthCodexUsageProvider(env: env, httpClient: camelOnlyClient, now: { self.now })
        do {
            _ = try await camelOnlyProvider.fetchUsage()
            Issue.record("camelCase accessToken must fail the OAuth provider closed")
        } catch let error as CodexUsageProviderError {
            #expect(error == .missingCredentials)
        }
        #expect(await camelOnlyClient.calls() == 0)

        try Data(#"{"tokens":{"api_key":"test-nested-api-key"}}"#.utf8)
            .write(to: authURL, options: .atomic)
        let nestedAPIKeyClient = RecordingUsageHTTPClient(responseData: Self.oauthResponseData)
        let nestedAPIKeyProvider = OAuthCodexUsageProvider(
            env: env,
            httpClient: nestedAPIKeyClient,
            now: { self.now })
        do {
            _ = try await nestedAPIKeyProvider.fetchUsage()
            Issue.record("nested API-key-only auth must fail the OAuth provider closed")
        } catch let error as CodexUsageProviderError {
            #expect(error == .missingCredentials)
        }
        #expect(await nestedAPIKeyClient.calls() == 0)

        try Data(
            #"{"OPENAI_API_KEY":"test-api-ignored","tokens":{"access_token":"test-oauth","account_id":"test-account"}}"#.utf8)
            .write(to: authURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authURL.path)
        let mixedClient = RecordingUsageHTTPClient(responseData: Self.oauthResponseData)
        let mixedProvider = OAuthCodexUsageProvider(env: env, httpClient: mixedClient, now: { self.now })
        _ = try await mixedProvider.fetchUsage()
        #expect(await mixedClient.calls() == 1)
        #expect(await mixedClient.authorization() == "Bearer test-oauth")
    }

    @Test
    func firstSuccessfulSourceWinsWithoutMerge() async throws {
        let first = TestProvider(results: [.failure(.processFailed("failed"))])
        let winnerSnapshot = self.snapshot(session: 77, weekly: 22, source: .cliRPC)
        let second = TestProvider(results: [.success(winnerSnapshot)])
        let third = TestProvider(results: [.success(self.snapshot(session: 1, weekly: 2))])
        let winner = try await CascadingCodexUsageProvider(providers: [first, second, third]).fetchUsage()
        #expect(winner.source == .cliRPC)
        #expect(winner.sessionPercentRemaining == 77)
        #expect(winner.weeklyPercentRemaining == 22)
        #expect(await first.calls() == 1)
        #expect(await second.calls() == 1)
        #expect(await third.calls() == 0)
    }

    @Test
    func localAnalyticsDoesNotRetainMessageText() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-balance-xctest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("synthetic.jsonl")
        try #"{"timestamp":"2027-01-15T05:00:00Z","payload":{"model":"gpt-5.4-codex","usage":{"input_tokens":1000,"output_tokens":300},"message":"PRIVATE_SENTINEL"}}"#
            .write(to: log, atomically: true, encoding: .utf8)
        let snapshot = try LocalUsageLogScanner.scanCodex(
            roots: [root],
            now: self.now)
        #expect(snapshot.last30DaysTokens == 1_300)
        #expect(snapshot.topModel == "gpt-5.4-codex")
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        #expect(!encoded.contains("PRIVATE_SENTINEL"))
    }

    @Test
    func diagnosticsSanitization() {
        let sanitized = UsageSnapshot.sanitized(
            "Authorization: Bearer private-value\n/Users/example/.codex/auth.json")
        #expect(!sanitized.contains("private-value"))
        #expect(!sanitized.contains("/Users/"))

        let analytics = LocalUsageAnalyticsSnapshot.unavailable(updatedAt: self.now)
        let state = UsageDiagnosticsFormatter.state(
            snapshot: self.snapshot(session: 35, weekly: 95),
            storeLastSuccess: self.now,
            storeLastError: "Authorization: Bearer private-value",
            mode: .automatic,
            presence: .active,
            nextRefreshAt: self.now.addingTimeInterval(60),
            analytics: analytics,
            analyticsLastSuccess: nil,
            now: self.now)
        let output = UsageDiagnosticsFormatter.exportText(state)
        #expect(!output.contains("private-value"))
        #expect(!output.contains("/Users/"))
        #expect(output.contains("Provider: OpenAI Codex"))
    }

    @Test
    @MainActor
    func refreshSingleFlightAndPresencePause() async {
        let provider = TestProvider(
            results: [.success(self.snapshot(session: 35, weekly: 95))],
            delay: .milliseconds(100))
        let cacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-balance-xctest-cache-\(UUID().uuidString).json")
        let store = UsageStore(provider: provider, cache: UsageSnapshotCache(url: cacheURL))
        store.replaceSnapshotForTesting(self.snapshot(session: 35, weekly: 95))
        let scheduler = RefreshScheduler(
            store: store,
            defaults: UserDefaults(suiteName: "CodexBalance.XCTest.\(UUID().uuidString)")!,
            now: { self.now },
            jitterUnit: { 0.5 })
        #expect(scheduler.refreshNow())
        #expect(!scheduler.refreshNow())
        #expect(await scheduler.refreshNowAndWait())
        #expect(await provider.calls() == 1)
        scheduler.updatePresence(.locked)
        #expect(!scheduler.refreshNow())
        #expect(scheduler.countdownText(now: self.now).contains("locked"))
        scheduler.setMode(.manual)
        #expect(scheduler.nextIntervalForTesting() == nil)
    }

    private func snapshot(
        session: Double,
        weekly: Double,
        source: UsageSource = .fixture) -> UsageSnapshot
    {
        UsageSnapshot(
            sessionPercentRemaining: session,
            weeklyPercentRemaining: weekly,
            sessionResetAt: self.now.addingTimeInterval(3_600),
            weeklyResetAt: self.now.addingTimeInterval(5 * 86_400),
            source: source,
            updatedAt: self.now)
    }

    private static let oauthResponseData = Data("""
    {"rate_limit":{"primary_window":{"used_percent":25,"reset_at":1800010000,"limit_window_seconds":18000},"secondary_window":{"used_percent":60,"reset_at":1800300000,"limit_window_seconds":604800}}}
    """.utf8)
}

private actor RecordingUsageHTTPClient: UsageHTTPClient {
    private let responseData: Data
    private var requests: [URLRequest] = []

    init(responseData: Data) {
        self.responseData = responseData
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [:])!
        return (self.responseData, response)
    }

    func calls() -> Int { self.requests.count }
    func authorization() -> String? { self.requests.last?.value(forHTTPHeaderField: "Authorization") }
}

private actor TestProvider: CodexUsageProviding {
    private var results: [Result<UsageSnapshot, CodexUsageProviderError>]
    private let delay: Duration?
    private var callCount = 0

    init(
        results: [Result<UsageSnapshot, CodexUsageProviderError>],
        delay: Duration? = nil)
    {
        self.results = results
        self.delay = delay
    }

    func fetchUsage() async throws -> UsageSnapshot {
        self.callCount += 1
        if let delay { try await Task.sleep(for: delay) }
        guard !self.results.isEmpty else { throw CodexUsageProviderError.noUsageWindows }
        return try self.results.removeFirst().get()
    }

    func calls() -> Int { self.callCount }
}
