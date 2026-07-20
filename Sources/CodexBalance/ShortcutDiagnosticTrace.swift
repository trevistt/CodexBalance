import AppKit
import Foundation

/// Fixture-only event trace for bounded keyboard routing diagnostics.
/// The trace records UI state categories only; it never records usage,
/// provider responses, credentials, file contents, or account data.
@MainActor
enum ShortcutDiagnosticTrace {
    private static var outputURL: URL?
    private static var sequence = 0

    static func configure(arguments: [String], fixtureNonce: String?) {
        guard fixtureNonce != nil,
              let argument = arguments.first(where: { $0.hasPrefix("--ui-qa-shortcut-trace=") })
        else { return }
        let path = String(argument.dropFirst("--ui-qa-shortcut-trace=".count))
        guard path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/") else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path)
        self.outputURL = url
        self.record("trace.configured")
    }

    static func record(
        _ event: String,
        panel: NSPanel? = nil,
        interactive: Bool? = nil,
        fields: [String: String] = [:])
    {
        guard let outputURL else { return }
        self.sequence += 1
        var values = fields
        if let interactive {
            values["panelInteractive"] = interactive ? "true" : "false"
        }
        if let panel {
            values["panelVisible"] = panel.isVisible ? "true" : "false"
            values["panelKey"] = panel.isKeyWindow ? "true" : "false"
            values["firstResponder"] = panel.firstResponder
                .map { String(describing: type(of: $0)) } ?? "none"
        }
        values["appActive"] = NSApp.isActive ? "true" : "false"
        values["keyWindow"] = {
            guard let key = NSApp.keyWindow else { return "none" }
            return key === panel ? "panel" : "other"
        }()
        let details = values.keys.sorted().map {
            "\(self.sanitize($0))=\(self.sanitize(values[$0] ?? ""))"
        }.joined(separator: ";")
        let row = String(
            format: "%.6f\t%d\t%@\t%@\n",
            Date().timeIntervalSince1970,
            self.sequence,
            self.sanitize(event),
            details)
        guard let data = row.data(using: .utf8),
              let handle = try? FileHandle(forWritingTo: outputURL)
        else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private static func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .prefix(80)
            .description
    }
}
