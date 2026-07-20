import Foundation

public struct LocalCodexUsageProvider: CodexUsageProviding, Sendable {
    private let env: [String: String]
    private let now: @Sendable () -> Date

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.env = env
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        if let snapshot = try self.scanSessionLogs() {
            return snapshot
        }
        throw CodexUsageProviderError.noUsageWindows
    }

    private func codexHome() -> URL {
        if let codexHome = self.env["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome)
        }
        if let home = self.env["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent(".codex")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private func scanSessionLogs() throws -> UsageSnapshot? {
        let sessions = self.codexHome().appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessions.path) else { return nil }

        let files = self.jsonlFiles(under: sessions)
            .sorted { lhs, rhs in
                self.modificationDate(lhs) > self.modificationDate(rhs)
            }
            .prefix(25)

        for file in files {
            if let snapshot = try self.latestSnapshot(in: file) {
                return snapshot
            }
        }
        return nil
    }

    private func jsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else
        {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }

    private func latestSnapshot(in file: URL) throws -> UsageSnapshot? {
        let raw = try String(contentsOf: file, encoding: .utf8)
        for line in raw.split(whereSeparator: \.isNewline).reversed() {
            guard let data = String(line).data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let rateLimits = Self.findRateLimits(in: json) else
            {
                continue
            }
            let session = Self.window(named: "five_hour", in: rateLimits, seconds: 18_000)
            let weekly = Self.window(named: "seven_day", in: rateLimits, seconds: 604_800)
            let snapshot = UsageSnapshot.fromWindows(
                primary: session,
                secondary: weekly,
                source: .localFallback,
                updatedAt: self.now())
            if snapshot.sessionPercentRemaining != nil || snapshot.weeklyPercentRemaining != nil {
                return snapshot
            }
        }
        return nil
    }

    private static func findRateLimits(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if let limits = dictionary["rate_limits"] as? [String: Any],
               limits["five_hour"] != nil || limits["seven_day"] != nil
            {
                return limits
            }
            for value in dictionary.values {
                if let found = self.findRateLimits(in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = self.findRateLimits(in: value) {
                    return found
                }
            }
        }
        return nil
    }

    private static func window(named name: String, in rateLimits: [String: Any], seconds: Int) -> UsageWindow? {
        guard let raw = rateLimits[name] as? [String: Any] else { return nil }
        let used = self.doubleValue(raw["used_percentage"] ?? raw["used_percent"])
        let reset = self.intValue(raw["resets_at"] ?? raw["reset_at"])
        guard let used else { return nil }
        return UsageWindow(
            usedPercent: used,
            resetAt: reset.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowSeconds: seconds)
    }

    private static func doubleValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as Double:
            value
        case let value as Int:
            Double(value)
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            value
        case let value as Double:
            Int(value)
        case let value as NSNumber:
            value.intValue
        case let value as String:
            Int(value)
        default:
            nil
        }
    }
}
