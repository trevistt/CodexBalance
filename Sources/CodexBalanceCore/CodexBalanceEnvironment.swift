import Foundation

public enum CodexBalanceEnvironment {
    public static func value(
        _ name: String,
        in env: [String: String] = ProcessInfo.processInfo.environment)
        -> String?
    {
        guard let value = env[name], !value.isEmpty else { return nil }
        return value
    }

    public static func isEnabled(
        _ name: String,
        in env: [String: String] = ProcessInfo.processInfo.environment)
        -> Bool
    {
        self.value(name, in: env) == "1"
    }

    public static func isExplicitlySet(
        _ name: String,
        in env: [String: String] = ProcessInfo.processInfo.environment)
        -> Bool
    {
        env[name]?.isEmpty == false
    }
}
