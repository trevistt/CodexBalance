import Darwin
import Foundation

public struct CLIRPCCodexUsageProvider: CodexUsageProviding, Sendable {
    private let env: [String: String]
    private let executable: String
    private let initializeTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        env: [String: String] = ProcessInfo.processInfo.environment,
        executable: String = "codex",
        initializeTimeout: TimeInterval = 8,
        requestTimeout: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = Date.init)
    {
        self.env = env
        self.executable = executable
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
        self.now = now
    }

    public func fetchUsage() async throws -> UsageSnapshot {
        try await Task.detached(priority: .utility) {
            try self.fetchUsageBlocking()
        }.value
    }

    private func fetchUsageBlocking() throws -> UsageSnapshot {
        let client = try RPCClient(
            env: self.env,
            executable: self.resolvedExecutable(),
            initializeTimeout: self.initializeTimeout,
            requestTimeout: self.requestTimeout)
        defer { client.shutdown() }

        try client.initialize()
        let limits: RPCRateLimitsResponse = try client.request(method: "account/rateLimits/read")
        let snapshot = UsageSnapshot.fromWindows(
            primary: limits.rateLimits.primary?.usageWindow,
            secondary: limits.rateLimits.secondary?.usageWindow,
            source: .cliRPC,
            updatedAt: self.now())
        guard snapshot.sessionPercentRemaining != nil || snapshot.weeklyPercentRemaining != nil else {
            throw CodexUsageProviderError.noUsageWindows
        }
        return snapshot
    }

    private func resolvedExecutable() -> String {
        if let override = CodexBalanceEnvironment.value("CODEX_BALANCE_CODEX_PATH", in: self.env) { return override }
        if let override = self.env["CODEX_CLI_PATH"], !override.isEmpty { return override }
        return self.executable
    }
}

private final class RPCClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var nextID = 1
    private let initializeTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let reader: NonBlockingLineReader

    init(env: [String: String], executable: String, initializeTimeout: TimeInterval, requestTimeout: TimeInterval) throws {
        self.initializeTimeout = initializeTimeout
        self.requestTimeout = requestTimeout
        self.reader = NonBlockingLineReader(fileHandle: self.stdoutPipe.fileHandleForReading)

        var processEnv = env
        if processEnv["PATH"] == nil || processEnv["PATH"]?.isEmpty == true {
            processEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        self.process.environment = processEnv
        self.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        self.process.arguments = [executable, "-s", "read-only", "-a", "untrusted", "app-server"]
        self.process.standardInput = self.stdinPipe
        self.process.standardOutput = self.stdoutPipe
        self.process.standardError = FileHandle.nullDevice

        do {
            try self.process.run()
        } catch {
            throw CodexUsageProviderError.processFailed(error.localizedDescription)
        }
    }

    func initialize() throws {
        let _: EmptyRPCResult = try self.request(
            method: "initialize",
            params: ["clientInfo": ["name": "codex-balance", "version": "0.1.1"]],
            timeout: self.initializeTimeout)
        try self.sendNotification(method: "initialized")
    }

    func request<T: Decodable>(
        method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval? = nil) throws -> T
    {
        let id = self.nextID
        self.nextID += 1
        try self.sendPayload(["id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(timeout ?? self.requestTimeout)

        while Date() < deadline {
            guard let line = try self.reader.readLine(deadline: deadline) else {
                continue
            }
            let object = try JSONSerialization.jsonObject(with: line)
            guard let message = object as? [String: Any] else { continue }
            if message["id"] == nil { continue }
            guard Self.intID(message["id"]) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "unknown JSON-RPC error"
                throw CodexUsageProviderError.processFailed(message)
            }
            guard let result = message["result"] else {
                throw CodexUsageProviderError.invalidResponse("missing result")
            }
            let data = try JSONSerialization.data(withJSONObject: result)
            return try JSONDecoder().decode(T.self, from: data)
        }

        self.shutdown()
        throw CodexUsageProviderError.timedOut(method)
    }

    func shutdown() {
        if self.process.isRunning {
            self.process.terminate()
        }
    }

    private func sendNotification(method: String) throws {
        try self.sendPayload(["method": method, "params": [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        self.stdinPipe.fileHandleForWriting.write(data)
        self.stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private static func intID(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }
}

private final class NonBlockingLineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fileHandle: FileHandle) {
        self.fd = fileHandle.fileDescriptor
        let flags = fcntl(self.fd, F_GETFL, 0)
        _ = fcntl(self.fd, F_SETFL, flags | O_NONBLOCK)
    }

    func readLine(deadline: Date) throws -> Data? {
        while Date() < deadline {
            if let line = self.drainBufferedLine() {
                return line
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(self.fd, &bytes, bytes.count)
            if count > 0 {
                self.buffer.append(contentsOf: bytes.prefix(count))
                continue
            }
            if count == 0 {
                throw CodexUsageProviderError.processFailed("app-server closed stdout")
            }
            if errno != EAGAIN && errno != EWOULDBLOCK {
                throw CodexUsageProviderError.processFailed(String(cString: strerror(errno)))
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }

    private func drainBufferedLine() -> Data? {
        guard let newline = self.buffer.firstIndex(of: 0x0A) else { return nil }
        let line = Data(self.buffer[..<newline])
        self.buffer.removeSubrange(...newline)
        return line.isEmpty ? self.drainBufferedLine() : line
    }
}

private struct EmptyRPCResult: Decodable {}

private struct RPCRateLimitsResponse: Decodable {
    let rateLimits: RPCRateLimits
}

private struct RPCRateLimits: Decodable {
    let primary: RPCWindow?
    let secondary: RPCWindow?
}

private struct RPCWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent
        case usedPercentSnake = "used_percent"
        case windowDurationMins
        case windowDurationMinsSnake = "window_duration_mins"
        case resetsAt
        case resetsAtSnake = "resets_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try container.flexibleDoubleIfPresent(forKey: .usedPercent)
            ?? container.flexibleDouble(forKey: .usedPercentSnake)
        self.windowDurationMins = try container.flexibleIntIfPresent(forKey: .windowDurationMins)
            ?? container.flexibleIntIfPresent(forKey: .windowDurationMinsSnake)
        self.resetsAt = try container.flexibleIntIfPresent(forKey: .resetsAt)
            ?? container.flexibleIntIfPresent(forKey: .resetsAtSnake)
    }

    var usageWindow: UsageWindow {
        UsageWindow(
            usedPercent: self.usedPercent,
            resetAt: self.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            windowSeconds: self.windowDurationMins.map { $0 * 60 })
    }
}

extension KeyedDecodingContainer {
    func flexibleDoubleIfPresent(forKey key: Key) throws -> Double? {
        guard self.contains(key), (try? self.decodeNil(forKey: key)) == false else { return nil }
        return try self.flexibleDouble(forKey: key)
    }

    func flexibleIntIfPresent(forKey key: Key) throws -> Int? {
        guard self.contains(key), (try? self.decodeNil(forKey: key)) == false else { return nil }
        return try self.flexibleInt(forKey: key)
    }
}
