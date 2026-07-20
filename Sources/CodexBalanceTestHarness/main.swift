import Foundation
import CodexBalanceCore

#if canImport(SQLite3)
import SQLite3
#endif

@main
struct CodexBalanceTestHarness {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--di-performance") {
            do {
                try await self.runDecisionIntelligencePerformance()
                return
            } catch {
                fputs("PERFORMANCE_FAIL: \(UsageSnapshot.sanitized(error.localizedDescription))\n", stderr)
                exit(1)
            }
        }
        var assertions = 0
        var failures: [String] = []

        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            if !condition() { failures.append(message) }
        }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let session = UsageWindow(
            usedPercent: 35,
            resetAt: now.addingTimeInterval(12_000),
            windowSeconds: 18_000)
        let weekly = UsageWindow(
            usedPercent: 70,
            resetAt: now.addingTimeInterval(300_000),
            windowSeconds: 604_800)
        let snapshot = UsageSnapshot.fromWindows(
            primary: session,
            secondary: weekly,
            source: .fixture,
            updatedAt: now)
        check(snapshot.sessionPercentRemaining == 65, "Session remaining")
        check(snapshot.weeklyPercentRemaining == 30, "Weekly remaining")
        check(snapshot.sessionResetAt == session.resetAt, "Session reset")
        check(snapshot.weeklyResetAt == weekly.resetAt, "Weekly reset")
        check(snapshot.verifiedAt == now, "Fresh snapshot verification")

        let weeklyOnly = UsageSnapshot.fromWindows(
            primary: weekly,
            secondary: nil,
            source: .fixture,
            updatedAt: now)
        check(weeklyOnly.sessionPercentRemaining == nil, "Weekly-only does not synthesize Session")
        check(weeklyOnly.weeklyPercentRemaining == 30, "Weekly-only promotion")
        let unknownA = UsageWindow(usedPercent: 20, resetAt: nil, windowSeconds: nil)
        let unknownB = UsageWindow(usedPercent: 40, resetAt: nil, windowSeconds: nil)
        let unknowns = UsageWindowNormalizer.normalize(primary: unknownA, secondary: unknownB)
        check(unknowns.session?.remainingPercent == 80, "Unknown primary fallback")
        check(unknowns.weekly?.remainingPercent == 60, "Unknown secondary fallback")

        let healthyDisplay = UsageDisplayFormatter.menuBarPresentation(snapshot: snapshot, now: now)
        check(healthyDisplay.rows.count == 2, "Menu two rows")
        check(healthyDisplay.rows[0].value == "65%", "Menu Session value")
        check(healthyDisplay.rows[1].marker == "W", "Menu Weekly marker")
        check(healthyDisplay.rows[1].value == "30%", "Menu Weekly value")
        check(healthyDisplay.rows[0].resetText == "3h 20m", "Menu Session reset")
        check(healthyDisplay.accessibilityText.contains("OpenAI Codex"), "Menu AX provider")
        let weeklyDisplay = UsageDisplayFormatter.menuBarPresentation(snapshot: weeklyOnly, now: now)
        check(weeklyDisplay.rows.count == 1, "Weekly-only menu one row")
        check(weeklyDisplay.rows[0].windowRole == .weekly, "Weekly-only menu role")
        check(weeklyDisplay.rows[0].marker == nil, "Weekly-only menu avoids duplicate role marker")
        check(weeklyDisplay.rows[0].resetText == "3d 11h", "Weekly-only menu reset")
        let stale = snapshot.markedStale(errorMessage: "Temporary failure.")
        let staleDisplay = UsageDisplayFormatter.menuBarPresentation(snapshot: stale, now: now)
        check(staleDisplay.rows[0].value == "65!", "Stale Session marker")
        check(staleDisplay.rows[1].value == "30!", "Stale Weekly marker")
        check(staleDisplay.accessibilityText.contains("cached stale"), "Stale AX truth")
        let expired = snapshot.markedStale(errorMessage: "Temporary failure.")
        let expiredDisplay = UsageDisplayFormatter.menuBarPresentation(
            snapshot: expired,
            now: now.addingTimeInterval(700_000))
        check(expiredDisplay.rows.allSatisfy { $0.value == "--!" }, "Expired stale cache hidden")
        let errorDisplay = UsageDisplayFormatter.menuBarPresentation(
            snapshot: .error("Provider failure.", updatedAt: now),
            now: now)
        check(errorDisplay.rows.first?.value == "--", "Hard error compact state")
        let loadingDisplay = UsageDisplayFormatter.menuBarPresentation(
            snapshot: .loading(updatedAt: now),
            isRefreshing: true,
            now: now)
        check(loadingDisplay.accessibilityText.contains("loading"), "Loading AX state")
        let loadingDecision = UsageDecisionEngine.make(
            snapshot: .loading(updatedAt: now),
            observation: UsageObservationState(),
            now: now)
        check(loadingDecision.headline == "Checking Codex quota", "Initial loading is not an error decision")
        check(!loadingDecision.isCaution, "Initial loading is neutral")

        if let pace = UsagePace(window: UsageWindow(
            usedPercent: 20,
            resetAt: now.addingTimeInterval(9_000),
            windowSeconds: 18_000), now: now)
        {
            check(pace.expectedUsedPercent == 50, "Pace expected")
            if case let .reserve(value) = pace.balance {
                check(Int(value.rounded()) == 30, "Pace reserve")
            } else {
                check(false, "Pace reserve classification")
            }
            check(pace.lastsUntilReset, "Reserve lasts")
            check(UsagePaceFormatter.projectionText(pace, now: now) == "Lasts until reset", "Reserve projection")
        } else {
            check(false, "Reserve pace exists")
            check(false, "Reserve classification exists")
            check(false, "Reserve lasts exists")
            check(false, "Reserve projection exists")
        }
        if let pace = UsagePace(window: UsageWindow(
            usedPercent: 80,
            resetAt: now.addingTimeInterval(9_000),
            windowSeconds: 18_000), now: now)
        {
            if case let .deficit(value) = pace.balance {
                check(Int(value.rounded()) == 30, "Pace deficit")
            } else {
                check(false, "Pace deficit classification")
            }
            check(!pace.lastsUntilReset, "Deficit run-out")
            check(UsagePaceFormatter.projectionText(pace, now: now).hasPrefix("Runs out in"), "Run-out copy")
        } else {
            check(false, "Deficit pace exists")
            check(false, "Deficit run-out exists")
            check(false, "Deficit projection exists")
        }
        check(UsageSnapshot.countdown(to: now.addingTimeInterval(60.1), now: now) == "1m", "Countdown ceil")
        check(UsageSnapshot.countdown(to: now.addingTimeInterval(0.1), now: now) == "<1m", "Countdown sub-minute")

        let oauthJSON = """
        {
          "rate_limit": {
            "primary_window": {"used_percent": 25, "reset_at": 1800010000, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 60, "reset_at": 1800300000, "limit_window_seconds": 604800}
          },
          "additional_rate_limits": [
            {
              "limit_name": "Codex Spark",
              "rate_limit": {
                "primary_window": {"used_percent": 10, "reset_at": 1800012000, "limit_window_seconds": 18000},
                "secondary_window": {"used_percent": 20, "reset_at": 1800400000, "limit_window_seconds": 604800}
              }
            },
            {"limit_name": "broken", "rate_limit": {"primary_window": "invalid"}}
          ]
        }
        """
        do {
            let mapped = try OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.mapUsageResponse(
                Data(oauthJSON.utf8),
                source: .oauth,
                updatedAt: now)
            check(mapped.sessionPercentRemaining == 75, "OAuth Session map")
            check(mapped.weeklyPercentRemaining == 40, "OAuth Weekly map")
            check(mapped.extraWindows.count == 2, "OAuth Spark windows")
            check(mapped.extraWindows.map(\.id).contains("codex-spark"), "OAuth Spark Session ID")
            check(mapped.extraWindows.map(\.id).contains("codex-spark-weekly"), "OAuth Spark Weekly ID")
        } catch {
            check(false, "OAuth fixture map")
            check(false, "OAuth fixture Weekly")
            check(false, "OAuth fixture extras")
            check(false, "OAuth fixture IDs")
            check(false, "OAuth fixture Weekly ID")
        }
        let protectedUsageURL = OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.usageURL(env: [
            "CODEX_BALANCE_ALLOW_USAGE_URL_OVERRIDE": "1",
            "CODEX_BALANCE_USAGE_URL": "https://untrusted.example/usage",
        ])
        check(protectedUsageURL.host == "chatgpt.com", "OAuth endpoint cannot be redirected by environment")
        check(
            URLSessionUsageHTTPClient.redirectRequest(for: URLRequest(url: URL(string: "https://untrusted.example/usage")!)) == nil,
            "OAuth HTTP client rejects redirects")
        check(OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.parseRetryAfter("42", now: now) == 42, "Retry-After delta seconds")
        check(OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.parseRetryAfter("Fri, 15 Jan 2027 08:01:00 GMT", now: now) == 60, "Retry-After HTTP date")
        check(OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.parseRetryAfter("Fri, 15 Jan 2027 07:59:00 GMT", now: now) == 0, "Retry-After past date")
        check(OAuthCodexUsageProvider<URLSessionUsageHTTPClient>.parseRetryAfter("not-a-date", now: now) == nil, "Retry-After malformed")

        do {
            let credentials = try CodexOAuthCredentialsStore.parse(data: Data(
                #"{"tokens":{"access_token":"test-access","account_id":"test-account"}}"#.utf8))
            check(credentials.accessToken == "test-access", "Credential parser")
            check(credentials.accountId == "test-account", "Credential account")
        } catch {
            check(false, "Credential parser")
            check(false, "Credential account")
        }

        let oauthAuthRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-balance-oauth-harness-\(UUID().uuidString)", isDirectory: true)
        let oauthAuthURL = oauthAuthRoot.appendingPathComponent("auth.json")
        let oauthEnv = ["CODEX_BALANCE_AUTH_PATH": oauthAuthURL.path]
        let oauthResponseData = Data("""
        {"rate_limit":{"primary_window":{"used_percent":25,"reset_at":1800010000,"limit_window_seconds":18000},"secondary_window":{"used_percent":60,"reset_at":1800300000,"limit_window_seconds":604800}}}
        """.utf8)
        do {
            try FileManager.default.createDirectory(at: oauthAuthRoot, withIntermediateDirectories: true)
            try Data(#"{"OPENAI_API_KEY":"test-api-only"}"#.utf8).write(to: oauthAuthURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oauthAuthURL.path)
            let apiOnlyClient = RecordingUsageHTTPClient(responseData: oauthResponseData)
            let apiOnlyProvider = OAuthCodexUsageProvider(env: oauthEnv, httpClient: apiOnlyClient, now: { now })
            var rejectedAPIKey = false
            do {
                _ = try await apiOnlyProvider.fetchUsage()
            } catch let error as CodexUsageProviderError {
                rejectedAPIKey = error == .missingCredentials
            }
            check(rejectedAPIKey, "OAuth provider rejects API-key-only auth")
            let apiOnlyCalls = await apiOnlyClient.calls()
            check(apiOnlyCalls == 0, "API-key-only auth makes no HTTP request")

            try Data(#"{"tokens":{"accessToken":"test-camel-only"}}"#.utf8)
                .write(to: oauthAuthURL, options: .atomic)
            let camelOnlyClient = RecordingUsageHTTPClient(responseData: oauthResponseData)
            let camelOnlyProvider = OAuthCodexUsageProvider(
                env: oauthEnv,
                httpClient: camelOnlyClient,
                now: { now })
            var rejectedCamelToken = false
            do {
                _ = try await camelOnlyProvider.fetchUsage()
            } catch let error as CodexUsageProviderError {
                rejectedCamelToken = error == .missingCredentials
            }
            check(rejectedCamelToken, "OAuth provider rejects camelCase-only accessToken")
            let camelOnlyCalls = await camelOnlyClient.calls()
            check(camelOnlyCalls == 0, "camelCase-only accessToken makes no HTTP request")

            try Data(#"{"tokens":{"api_key":"test-nested-api-key"}}"#.utf8)
                .write(to: oauthAuthURL, options: .atomic)
            let nestedAPIKeyClient = RecordingUsageHTTPClient(responseData: oauthResponseData)
            let nestedAPIKeyProvider = OAuthCodexUsageProvider(
                env: oauthEnv,
                httpClient: nestedAPIKeyClient,
                now: { now })
            var rejectedNestedAPIKey = false
            do {
                _ = try await nestedAPIKeyProvider.fetchUsage()
            } catch let error as CodexUsageProviderError {
                rejectedNestedAPIKey = error == .missingCredentials
            }
            check(rejectedNestedAPIKey, "OAuth provider rejects nested API-key-only auth")
            let nestedAPIKeyCalls = await nestedAPIKeyClient.calls()
            check(nestedAPIKeyCalls == 0, "Nested API-key-only auth makes no HTTP request")

            try Data(
                #"{"OPENAI_API_KEY":"test-api-ignored","tokens":{"access_token":"test-oauth","account_id":"test-account"}}"#.utf8)
                .write(to: oauthAuthURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oauthAuthURL.path)
            let mixedClient = RecordingUsageHTTPClient(responseData: oauthResponseData)
            let mixedProvider = OAuthCodexUsageProvider(env: oauthEnv, httpClient: mixedClient, now: { now })
            _ = try await mixedProvider.fetchUsage()
            let mixedCalls = await mixedClient.calls()
            let mixedAuthorization = await mixedClient.authorization()
            check(mixedCalls == 1, "Mixed auth makes one OAuth request")
            check(mixedAuthorization == "Bearer test-oauth", "Mixed auth uses only ChatGPT OAuth token")
        } catch {
            check(false, "OAuth API-key rejection fixture")
            check(false, "OAuth no-request fixture")
            check(false, "OAuth camelCase token rejection fixture")
            check(false, "OAuth camelCase token no-request fixture")
            check(false, "OAuth nested API-key rejection fixture")
            check(false, "OAuth nested API-key no-request fixture")
            check(false, "OAuth mixed-auth request fixture")
            check(false, "OAuth mixed-auth token fixture")
        }
        try? FileManager.default.removeItem(at: oauthAuthRoot)

        let first = TestUsageProvider(results: [.failure(.processFailed("first failed"))])
        let secondSnapshot = UsageSnapshot(
            sessionPercentRemaining: 77,
            weeklyPercentRemaining: 22,
            sessionResetAt: now.addingTimeInterval(10_000),
            weeklyResetAt: now.addingTimeInterval(200_000),
            source: .cliRPC,
            updatedAt: now)
        let second = TestUsageProvider(results: [.success(secondSnapshot)])
        let third = TestUsageProvider(results: [.success(snapshot)])
        do {
            let winner = try await CascadingCodexUsageProvider(providers: [first, second, third]).fetchUsage()
            check(winner.source == .cliRPC, "Cascade first success source")
            check(winner.sessionPercentRemaining == 77, "Cascade no Session merge")
            check(winner.weeklyPercentRemaining == 22, "Cascade no Weekly merge")
            let firstCalls = await first.calls()
            let secondCalls = await second.calls()
            let thirdCalls = await third.calls()
            check(firstCalls == 1, "Cascade first called")
            check(secondCalls == 1, "Cascade second called")
            check(thirdCalls == 0, "Cascade stops after winner")
        } catch {
            for _ in 0..<6 { check(false, "Cascade failed") }
        }

        // DI1: equivalent snapshots are checks, not changes; a same-epoch
        // semantic difference is one observed change.
        var observations = UsageObservationState()
        check(!observations.recordVerified(snapshot, at: now), "Observation baseline is not a change")
        check(!observations.recordVerified(snapshot, at: now.addingTimeInterval(5)), "Observation A to A is unchanged")
        let changedSnapshot = UsageSnapshot(
            sessionPercentRemaining: 60,
            weeklyPercentRemaining: 30,
            sessionResetAt: snapshot.sessionResetAt,
            weeklyResetAt: snapshot.weeklyResetAt,
            source: .oauth,
            updatedAt: now.addingTimeInterval(10))
        check(observations.recordVerified(changedSnapshot, at: now.addingTimeInterval(10)), "Observation A to B changes once")
        check(observations.lastChangedAt == now.addingTimeInterval(10), "Observation change timestamp")
        let resetEpochSnapshot = UsageSnapshot(
            sessionPercentRemaining: 40,
            weeklyPercentRemaining: 30,
            sessionResetAt: now.addingTimeInterval(30_000),
            weeklyResetAt: snapshot.weeklyResetAt,
            source: .oauth,
            updatedAt: now.addingTimeInterval(20))
        check(!observations.recordVerified(resetEpochSnapshot, at: now.addingTimeInterval(20)), "Reset epoch establishes a baseline")
        let changeBeforeFailure = observations.lastChangedAt
        observations.recordAttempt(CodexProviderAttempt(source: .oauth, attemptedAt: now.addingTimeInterval(25), outcome: .cancelled), now: now.addingTimeInterval(25))
        check(observations.lastChangedAt == changeBeforeFailure, "Cancelled check does not change timestamp")
        check(CodexProviderOutcomeClassifier.classify(CodexUsageProviderError.authenticationRequired) == .authenticationRequired, "Typed auth outcome")
        check(CodexProviderOutcomeClassifier.classify(CodexUsageProviderError.rateLimited(retryAfter: 42)) == .rateLimited(retryAfter: 42), "Typed rate limit outcome")

        let cooldownPrimary = TestUsageProvider(results: [.failure(.authenticationRequired)])
        let fallbackOne = UsageSnapshot(
            sessionPercentRemaining: 71,
            weeklyPercentRemaining: 26,
            sessionResetAt: now.addingTimeInterval(5_000),
            weeklyResetAt: now.addingTimeInterval(200_000),
            source: .localFallback,
            updatedAt: now)
        let cooldownFallback = TestUsageProvider(results: [.success(fallbackOne), .success(fallbackOne)])
        let resolver = CodexUsageResolver(
            sources: [
                .init(kind: .oauth, provider: cooldownPrimary),
                .init(kind: .localFallback, provider: cooldownFallback),
            ],
            now: { now })
        do {
            let firstResolution = try await resolver.resolveUsage()
            check(firstResolution.snapshot.source == .localFallback, "Resolver first complete source wins")
            check(firstResolution.attempts.count == 2, "Resolver records source attempts")
            check(firstResolution.attempts.first?.outcome == .authenticationRequired, "Resolver records auth stop")
            let secondResolution = try await resolver.resolveUsage()
            check(secondResolution.snapshot.sessionPercentRemaining == 71, "Resolver preserves complete fallback snapshot")
            let primaryCalls = await cooldownPrimary.calls()
            check(primaryCalls == 1, "Resolver cooldown suppresses repeat OAuth call")
        } catch {
            for _ in 0..<6 { check(false, "Resolver cooldown fixture failed") }
        }

        let adaptive = AdaptiveRefreshPolicy()
        let adaptiveBase = AdaptiveRefreshInput(
            now: now,
            dashboardVisible: true,
            presence: .active,
            hasRecentActivity: false,
            unchangedChecks: 0,
            lastCheckedAt: now.addingTimeInterval(-4),
            isInFlight: false,
            cooldownUntil: nil,
            trigger: .automatic)
        check(adaptive.decide(adaptiveBase, jitterUnit: 0.5).nextInterval == 10, "Adaptive visible ten seconds")
        var quietInput = adaptiveBase
        quietInput.dashboardVisible = false
        quietInput.unchangedChecks = 3
        check(adaptive.decide(quietInput, jitterUnit: 0.5).nextInterval == 60, "Adaptive quiet sixty seconds")
        var cooldownInput = adaptiveBase
        cooldownInput.trigger = .manual
        cooldownInput.cooldownUntil = now.addingTimeInterval(90)
        check(!adaptive.decide(cooldownInput).refreshNow, "Manual respects cooldown")
        check(adaptive.allowsDurableWrite(at: now, previousWrites: [now.addingTimeInterval(-50)]), "Durable write under cap")
        check(!adaptive.allowsDurableWrite(at: now, previousWrites: [now.addingTimeInterval(-50), now.addingTimeInterval(-20)]), "Durable write cap")
        var simulatedVisibleTicks = 0
        for tick in 0..<180 {
            var tickInput = adaptiveBase
            tickInput.now = now.addingTimeInterval(TimeInterval(tick * 10))
            if adaptive.decide(tickInput, jitterUnit: 0.5).nextInterval == 10 {
                simulatedVisibleTicks += 1
            }
        }
        check(simulatedVisibleTicks == 180, "Adaptive visible policy stays at ten seconds across a 30-minute simulation")

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-balance-codex-tests-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            let logs = temp.appendingPathComponent("sessions/2026/07/16", isDirectory: true)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let quotaURL = logs.appendingPathComponent("quota.jsonl")
            let quotaRecord = #"{"payload":{"rate_limits":{"five_hour":{"used_percentage":35,"resets_at":1800010000},"seven_day":{"used_percentage":70,"resets_at":1800300000}}}}"#
            try quotaRecord.write(to: quotaURL, atomically: true, encoding: .utf8)
            let local = try await LocalCodexUsageProvider(
                env: ["CODEX_HOME": temp.path],
                now: { now }).fetchUsage()
            check(local.source == .localFallback, "Session log fallback source")
            check(local.sessionPercentRemaining == 65, "Session log fallback Session")
            check(local.weeklyPercentRemaining == 30, "Session log fallback Weekly")

            let logURL = logs.appendingPathComponent("synthetic.jsonl")
            let lines = [
                #"{"timestamp":"2027-01-15T05:00:00Z","payload":{"model":"gpt-5.4-codex","usage":{"input_tokens":1000,"cached_input_tokens":200,"output_tokens":300},"message":"PRIVATE_SENTINEL"}}"#,
                #"{"timestamp":"2027-01-15T06:00:00Z","payload":{"model":"gpt-5.4-codex","usage":{"input_tokens":500,"output_tokens":100}}}"#,
                #"not-json"#,
            ].joined(separator: "\n")
            try lines.write(to: logURL, atomically: true, encoding: .utf8)
            let analytics = try LocalUsageLogScanner.scanCodex(
                roots: [logs],
                now: Date(timeIntervalSince1970: 1_800_000_000),
                options: .init(historyDays: 30, maxFiles: 100, maxLineBytes: 64 * 1024))
            check(analytics.hasAnyData, "Analytics has data")
            check(analytics.last30DaysTokens == 2_100, "Analytics token total")
            check(analytics.latestTokens == 600, "Analytics latest tokens")
            check(analytics.topModel == "gpt-5.4-codex", "Analytics top model")
            check(analytics.last30DaysCostUSD != nil, "Analytics estimated cost")
            check(analytics.dailyHistory.count == 30, "Analytics histogram buckets")
            let encoded = String(data: try JSONEncoder().encode(analytics), encoding: .utf8) ?? ""
            check(!encoded.contains("PRIVATE_SENTINEL"), "Analytics excludes message content")

            let index = LocalUsageIndex(url: temp.appendingPathComponent("index.json"))
            let firstIndexed = try index.refresh(roots: [logs], now: Date(timeIntervalSince1970: 1_800_000_000))
            let unchangedIndexed = try index.refresh(roots: [logs], now: Date(timeIntervalSince1970: 1_800_000_000))
            check(firstIndexed.payloadBytesRead > 0, "Index first scan reads JSONL")
            check(!firstIndexed.reusedUnchangedIndex, "Index first scan is not reused")
            check(unchangedIndexed.payloadBytesRead == 0, "Index unchanged scan reads zero JSONL bytes")
            check(unchangedIndexed.reusedUnchangedIndex, "Index reuses unchanged metadata")
            check(unchangedIndexed.snapshot == firstIndexed.snapshot, "Index unchanged snapshot equals full scan")
            try lines.appending("\n{\"timestamp\":\"2027-01-15T08:00:00Z\",\"model\":\"gpt-5.4-codex\",\"usage\":{\"input_tokens\":20,\"output_tokens\":10}}")
                .write(to: logURL, atomically: true, encoding: .utf8)
            let appendedIndexed = try index.refresh(roots: [logs], now: Date(timeIntervalSince1970: 1_800_000_000))
            check(!appendedIndexed.reusedUnchangedIndex, "Index notices appended JSONL")
            check(appendedIndexed.payloadBytesRead <= 256, "Index reads only the appended JSONL payload")
            check(appendedIndexed.snapshot.last30DaysTokens == 2_130, "Index append reconciliation")
            let fullAfterAppend = try LocalUsageLogScanner.scanCodex(
                roots: [logs],
                now: Date(timeIntervalSince1970: 1_800_000_000))
            check(appendedIndexed.snapshot == fullAfterAppend, "Index append equals full metadata scan")
            let indexJSON = String(data: try Data(contentsOf: temp.appendingPathComponent("index.json")), encoding: .utf8) ?? ""
            check(!indexJSON.contains("PRIVATE_SENTINEL") && !indexJSON.contains(logURL.path), "Index persists no message or path")

            let unknownLog = logs.appendingPathComponent("unknown.jsonl")
            try #"{"timestamp":"2027-01-15T07:00:00Z","model":"future-model","usage":{"input_tokens":10,"output_tokens":5}}"#
                .write(to: unknownLog, atomically: true, encoding: .utf8)
            let partial = try LocalUsageLogScanner.scanCodex(
                roots: [unknownLog],
                now: Date(timeIntervalSince1970: 1_800_000_000))
            check(partial.last30DaysTokens == 15, "Unknown model tokens retained")
            check(partial.last30DaysCostUSD == nil, "Unknown model cost unavailable")
            check(partial.isCostPartial, "Unknown model partial flag")
            check(LocalUsageAnalyticsFormatter.costText(nil) == "N/A", "Unavailable cost fits compact metric")

            let dedupRoot = temp.appendingPathComponent("dedup", isDirectory: true)
            try FileManager.default.createDirectory(at: dedupRoot, withIntermediateDirectories: true)
            let duplicateLine = #"{"timestamp":"2027-01-15T07:00:00Z","model":"gpt-5.4-codex","usage":{"input_tokens":40,"output_tokens":20}}"#
            try duplicateLine.write(to: dedupRoot.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
            try duplicateLine.write(to: dedupRoot.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
            let deduplicated = try LocalUsageLogScanner.scanCodex(
                roots: [dedupRoot],
                now: Date(timeIntervalSince1970: 1_800_000_000))
            check(deduplicated.last30DaysTokens == 60, "Duplicate JSONL event is counted once across files actual=\(deduplicated.last30DaysTokens ?? -1)")

            let newestRoot = temp.appendingPathComponent("newest", isDirectory: true)
            try FileManager.default.createDirectory(at: newestRoot, withIntermediateDirectories: true)
            let older = newestRoot.appendingPathComponent("older.jsonl")
            let newer = newestRoot.appendingPathComponent("newer.jsonl")
            try #"{"timestamp":"2027-01-15T07:00:00Z","model":"gpt-5.4-codex","usage":{"input_tokens":1,"output_tokens":1}}"#
                .write(to: older, atomically: true, encoding: .utf8)
            try #"{"timestamp":"2027-01-15T07:01:00Z","model":"gpt-5.4-codex","usage":{"input_tokens":9,"output_tokens":1}}"#
                .write(to: newer, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: older.path)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newer.path)
            let newestOnly = try LocalUsageLogScanner.scanCodex(
                roots: [newestRoot],
                now: now,
                options: .init(historyDays: 30, maxFiles: 1))
            check(newestOnly.last30DaysTokens == 10, "File cap retains newest JSONL metadata actual=\(newestOnly.last30DaysTokens ?? -1)")

            #if canImport(SQLite3)
            let dbURL = temp.appendingPathComponent("state.sqlite")
            var db: OpaquePointer?
            check(sqlite3_open(dbURL.path, &db) == SQLITE_OK, "SQLite fixture open")
            if let db {
                defer { sqlite3_close(db) }
                let sql = """
                CREATE TABLE threads(updated_at INTEGER, model TEXT, tokens_used INTEGER, model_provider TEXT);
                INSERT INTO threads VALUES(1799999000, 'gpt-5.4-codex', 1234, 'openai');
                """
                check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "SQLite fixture schema")
                let state = try LocalUsageLogScanner.scanCodexThreadState(
                    databaseURL: dbURL,
                    now: now)
                check(state.last30DaysTokens == nil, "SQLite cumulative tokens are not labelled 30d")
                check(state.todayTokens == nil && state.dailyHistory.isEmpty, "SQLite does not synthesize dated token history")
                check(state.sourceLabel == "Codex thread state (recent activity)", "SQLite source label")
                check(state.recentWork.first?.tokenActivity == 1_234, "SQLite retains partial recent activity")
                check(state.last30DaysCostUSD == nil, "SQLite cost unavailable without breakdown")
                check(state.isCostPartial, "SQLite analytics marks cost partial")

                let combinedProvider = CodexLocalLogAnalyticsProvider(
                    codexHome: temp,
                    now: { Date(timeIntervalSince1970: 1_800_000_000) },
                    index: LocalUsageIndex(url: temp.appendingPathComponent("provider-index.json")))
                let providerSnapshot = try await combinedProvider.fetchAnalytics()
                check(providerSnapshot.sourceLabel != "Codex thread state", "JSONL wins over SQLite fallback")
                check(providerSnapshot.last30DaysTokens == 2_145, "JSONL and SQLite totals never double count")
            } else {
                check(false, "SQLite handle")
                check(false, "SQLite schema")
                check(false, "SQLite total")
                check(false, "SQLite label")
                check(false, "SQLite cost")
                check(false, "SQLite partial")
            }
            #else
            check(true, "SQLite unavailable is explicit")
            check(true, "SQLite schema skipped")
            check(true, "SQLite total skipped")
            check(true, "SQLite label skipped")
            check(true, "SQLite cost skipped")
            check(true, "SQLite partial skipped")
            #endif
        } catch {
            for _ in 0..<20 { check(false, "Local fixture failure: \(error.localizedDescription)") }
        }

        let cacheURL = temp.appendingPathComponent("usage-cache.json")
        let cache = UsageSnapshotCache(url: cacheURL)
        cache.save(snapshot)
        let cached = cache.load()
        check(cached?.sessionPercentRemaining == 65, "Usage cache Session")
        check(cached?.weeklyPercentRemaining == 30, "Usage cache Weekly")
        let failingStore = UsageStore(
            provider: TestUsageProvider(results: [.failure(.processFailed("offline"))]),
            cache: cache)
        check(failingStore.snapshot.isStale, "Cached snapshot starts stale")
        _ = await failingStore.refresh()
        check(failingStore.snapshot.isStale, "Failure preserves stale cache")
        check(failingStore.snapshot.sessionPercentRemaining == 65, "Failure preserves Session")

        let delayed = TestUsageProvider(
            results: [.success(snapshot)],
            delay: .milliseconds(120))
        let schedulerStore = UsageStore(
            provider: delayed,
            cache: UsageSnapshotCache(url: temp.appendingPathComponent("scheduler-cache.json")))
        schedulerStore.replaceSnapshotForTesting(snapshot)
        let suite = UserDefaults(suiteName: "CodexBalance.Harness.\(UUID().uuidString)")!
        let scheduler = RefreshScheduler(
            store: schedulerStore,
            defaults: suite,
            now: { now },
            jitterUnit: { 0.5 })
        check(scheduler.nextIntervalForTesting() == 60, "Auto cadence healthy")
        check(scheduler.refreshNow(), "First manual refresh starts")
        check(!scheduler.refreshNow(), "Repeated refresh is single-flight")
        let refreshCompleted = await scheduler.refreshNowAndWait()
        let delayedCalls = await delayed.calls()
        check(refreshCompleted, "Single-flight refresh completes")
        check(delayedCalls == 1, "Provider called once")
        scheduler.updatePresence(.locked)
        check(!scheduler.refreshNow(), "Locked refresh paused")
        check(scheduler.countdownText(now: now).contains("locked"), "Locked pause reason")
        scheduler.updatePresence(.active)
        scheduler.setMode(.manual)
        check(scheduler.nextIntervalForTesting() == nil, "Manual mode no timer")
        scheduler.setMode(.seconds30)
        check(scheduler.nextIntervalForTesting() == 30, "30s cadence")
        scheduler.stop()

        let analyticsSnapshot = LocalUsageAnalyticsSnapshot(
            todayCostUSD: 0.1,
            todayTokens: 10_000,
            last30DaysCostUSD: 2,
            last30DaysTokens: 200_000,
            latestTokens: 2_000,
            topModel: "gpt-5.4-codex",
            dailyHistory: [],
            updatedAt: now)
        let state = UsageDiagnosticsFormatter.state(
            snapshot: snapshot,
            storeLastSuccess: now,
            storeLastError: "Authorization: Bearer hidden-value",
            mode: .automatic,
            presence: .active,
            nextRefreshAt: now.addingTimeInterval(60),
            analytics: analyticsSnapshot,
            analyticsLastSuccess: now,
            now: now)
        let diagnostics = UsageDiagnosticsFormatter.exportText(state)
        check(!diagnostics.contains("hidden-value"), "Diagnostics strips header value")
        check(!diagnostics.contains("/Users/"), "Diagnostics strips full path")
        check(diagnostics.contains("Provider: OpenAI Codex"), "Diagnostics provider")
        check(state.lastErrorCategory == "Authentication", "Diagnostics error category")
        let sanitized = UsageSnapshot.sanitized(
            "Authorization: Bearer hidden\npath=/Users/example/.codex/auth.json")
        check(!sanitized.contains("hidden"), "Sanitizer bearer")
        check(!sanitized.contains("/Users/"), "Sanitizer user path")

        let activityRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbalance-activity-monitor-\(UUID().uuidString)", isDirectory: true)
        let nestedSession = activityRoot.appendingPathComponent("sessions/2026/07/18", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: nestedSession, withIntermediateDirectories: true)
            let probe = ActivityProbe()
            let monitor = LocalUsageActivityMonitor(roots: [activityRoot]) {
                Task { await probe.signal() }
            }
            monitor.start()
            try await Task.sleep(for: .milliseconds(400))
            let appendBaseline = await probe.count()
            try Data("{}\n".utf8).write(to: nestedSession.appendingPathComponent("nested.jsonl"))
            let nestedAppendObserved = await probe.waitForChange(after: appendBaseline, timeout: 3)
            check(
                nestedAppendObserved,
                "Activity monitor observes nested session append")
            let directoryBaseline = await probe.count()
            let newDirectory = activityRoot.appendingPathComponent("sessions/2026/07/19", isDirectory: true)
            try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: newDirectory.appendingPathComponent("new-directory.jsonl"))
            let nestedDirectoryObserved = await probe.waitForChange(after: directoryBaseline, timeout: 3)
            check(
                nestedDirectoryObserved,
                "Activity monitor observes new nested directory")
            monitor.stop()
        } catch {
            check(false, "Activity monitor fixture failed: \(UsageSnapshot.sanitized(error.localizedDescription))")
            check(false, "Activity monitor new directory fixture failed")
        }
        try? FileManager.default.removeItem(at: activityRoot)

        try? FileManager.default.removeItem(at: temp)

        if failures.isEmpty {
            print("CodexBalanceTestHarness PASS assertions=\(assertions)")
            return
        }
        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        fputs("CodexBalanceTestHarness FAIL assertions=\(assertions) failures=\(failures.count)\n", stderr)
        exit(1)
    }

    private static func runDecisionIntelligencePerformance() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbalance-di-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("representative.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let writer = try FileHandle(forWritingTo: log)
        defer { try? writer.close() }
        let first = "{\"timestamp\":\"2026-07-18T01:00:00Z\",\"model\":\"gpt-5.4-codex\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500}}\n"
        try writer.write(contentsOf: Data(first.utf8))
        let block = Data(repeating: 0x20, count: 1_048_576)
        for _ in 0..<2_048 {
            try autoreleasepool { try writer.write(contentsOf: block) }
        }
        try writer.synchronize()
        let now = Date(timeIntervalSince1970: 1_784_350_800)
        let index = LocalUsageIndex(url: root.appendingPathComponent("index.json"))
        let coldStart = ContinuousClock.now
        let cold = try index.refresh(roots: [root], now: now)
        let coldElapsed = coldStart.duration(to: .now)
        let unchangedStart = ContinuousClock.now
        let unchanged = try index.refresh(roots: [root], now: now)
        let unchangedElapsed = unchangedStart.duration(to: .now)
        var appendDurations: [Duration] = []
        var appendReadBytes: [Int] = []
        var appended = unchanged
        let padding = Data(repeating: 0x20, count: 1_048_000)
        for indexValue in 0..<10 {
            let minute = String(format: "%02d", indexValue + 1)
            let append = "\n{\"timestamp\":\"2026-07-18T01:\(minute):00Z\",\"model\":\"gpt-5.4-codex\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}\n"
            try writer.write(contentsOf: Data(append.utf8))
            try writer.write(contentsOf: padding)
            try writer.synchronize()
            let appendStart = ContinuousClock.now
            appended = try index.refresh(roots: [root], now: now)
            appendDurations.append(appendStart.duration(to: .now))
            appendReadBytes.append(appended.payloadBytesRead)
        }
        guard cold.snapshot.last30DaysTokens == 1_500,
              unchanged.payloadBytesRead == 0,
              appended.snapshot.last30DaysTokens == 1_650,
              appendReadBytes.allSatisfy({ $0 > 1_048_000 && $0 <= 1_049_000 })
        else { throw LocalUsageAnalyticsError.scanFailed("Synthetic corpus reconciliation cold=\(cold.snapshot.last30DaysTokens ?? -1) unchangedRead=\(unchanged.payloadBytesRead) appended=\(appended.snapshot.last30DaysTokens ?? -1) appendRead=\(appendReadBytes.max() ?? -1).") }
        func milliseconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
        let size = (try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? NSNumber)?.int64Value ?? 0
        let coldMS = String(format: "%.1f", milliseconds(coldElapsed))
        let unchangedMS = String(format: "%.1f", milliseconds(unchangedElapsed))
        let sortedAppendMS = appendDurations.map(milliseconds).sorted()
        let appendP95 = sortedAppendMS[min(sortedAppendMS.count - 1, Int(ceil(Double(sortedAppendMS.count) * 0.95)) - 1)]
        let appendMS = String(format: "%.1f", appendP95)
        print("DI_PERF_PASS corpus_bytes=\(size) cold_ms=\(coldMS) cold_read_bytes=\(cold.payloadBytesRead) unchanged_ms=\(unchangedMS) unchanged_read_bytes=\(unchanged.payloadBytesRead) append_p95_ms=\(appendMS) append_max_read_bytes=\(appendReadBytes.max() ?? 0)")
    }
}

private actor ActivityProbe {
    private var signals = 0

    func signal() { self.signals += 1 }
    func count() -> Int { self.signals }

    func waitForChange(after baseline: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if self.signals > baseline { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return self.signals > baseline
    }
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

private actor TestUsageProvider: CodexUsageProviding {
    private var results: [Result<UsageSnapshot, CodexUsageProviderError>]
    private var callCount = 0
    private let delay: Duration?

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
        guard !self.results.isEmpty else {
            throw CodexUsageProviderError.noUsageWindows
        }
        return try self.results.removeFirst().get()
    }

    func calls() -> Int {
        self.callCount
    }
}
