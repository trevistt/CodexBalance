import AppKit
import Darwin

@main
enum CodexBalanceMain {
    @MainActor
    private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let arguments = ProcessInfo.processInfo.arguments
        app.setActivationPolicy(.accessory)

        if arguments.contains("--smoke-check") {
            exit(UISmokeCheck.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        if let request = Self.visualQARequest(arguments: arguments) {
            let passed = VisualQAFixtureRunner.run(
                outputURL: URL(fileURLWithPath: request.path),
                variant: request.variant)
            exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        let delegate = AppDelegate()
        self.appDelegate = delegate
        app.delegate = delegate
        delegate.bootstrap()
        app.run()
    }

    private static func visualQARequest(arguments: [String]) -> (variant: VisualQAVariant, path: String)? {
        for (index, argument) in arguments.enumerated() {
            guard argument.hasPrefix("--visual-qa-fixture") else { continue }
            guard arguments.indices.contains(index + 1) else { return nil }
            let suffix = argument
                .replacingOccurrences(of: "--visual-qa-fixture", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "-:"))
            return (
                VisualQAVariant(rawValue: suffix.isEmpty ? "session-weekly" : suffix)
                    ?? .sessionWeekly,
                arguments[index + 1])
        }
        return nil
    }
}
