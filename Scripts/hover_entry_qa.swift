#!/usr/bin/env swift

import AppKit
import ApplicationServices
import Foundation

private struct QAError: Error, CustomStringConvertible {
    let description: String
}

private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

private func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

private func identifier(_ element: AXUIElement) -> String? {
    attribute(element, kAXIdentifierAttribute) as? String
}

private func find(_ element: AXUIElement, identifier target: String) -> AXUIElement? {
    if identifier(element) == target { return element }
    for child in children(element) {
        if let match = find(child, identifier: target) { return match }
    }
    return nil
}

private func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionValue = attribute(element, kAXPositionAttribute),
          let sizeValue = attribute(element, kAXSizeAttribute),
          CFGetTypeID(positionValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
}

private func wait(
    timeout: TimeInterval,
    interval: TimeInterval = 0.025,
    _ condition: () -> Bool
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    } while Date() < deadline
    return condition()
}

private func moveMouse(to point: CGPoint) throws {
    guard let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: point,
        mouseButton: .left)
    else { throw QAError(description: "mouse_event_unavailable") }
    event.post(tap: .cghidEventTap)
    guard wait(timeout: 0.5, interval: 0.01, {
        guard let current = CGEvent(source: nil)?.location else { return false }
        return hypot(current.x - point.x, current.y - point.y) <= 2
    }) else { throw QAError(description: "cursor_position_not_observed") }
}

private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.5
        && abs(lhs.minY - rhs.minY) <= 0.5
        && abs(lhs.width - rhs.width) <= 0.5
        && abs(lhs.height - rhs.height) <= 0.5
}

private func stableFrame(_ element: AXUIElement) -> CGRect? {
    var previous: CGRect?
    var consecutive = 0
    let deadline = Date().addingTimeInterval(2)
    repeat {
        if let current = frame(element), current.width > 0, current.height > 0 {
            consecutive = previous.map { framesMatch($0, current) } == true ? consecutive + 1 : 1
            previous = current
            if consecutive >= 4 { return current }
        } else {
            previous = nil
            consecutive = 0
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    } while Date() < deadline
    return nil
}

private func append(_ row: String, to url: URL) {
    guard let data = (row + "\n").data(using: .utf8),
          let handle = try? FileHandle(forWritingTo: url)
    else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

private func main() throws {
    let arguments = CommandLine.arguments
    guard let pidIndex = arguments.firstIndex(of: "--pid"),
          arguments.indices.contains(pidIndex + 1),
          let pid = pid_t(arguments[pidIndex + 1]),
          let outputIndex = arguments.firstIndex(of: "--output"),
          arguments.indices.contains(outputIndex + 1)
    else { throw QAError(description: "invalid_arguments") }
    guard AXIsProcessTrusted() else { throw QAError(description: "accessibility_not_granted") }

    let traceURL = URL(fileURLWithPath: arguments[outputIndex + 1])
    FileManager.default.createFile(atPath: traceURL.path, contents: nil)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: traceURL.path)
    let started = Date()
    func trace(_ event: String, _ targetFrame: CGRect? = nil) {
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        let geometry = targetFrame.map {
            String(format: "\t%.1f\t%.1f\t%.1f\t%.1f", $0.minX, $0.minY, $0.width, $0.height)
        } ?? "\t-\t-\t-\t-"
        append("\(elapsed)\t\(event)\(geometry)", to: traceURL)
    }

    let app = AXUIElementCreateApplication(pid)
    guard wait(timeout: 2, { find(app, identifier: "codexbalance.status-item") != nil }),
          let status = find(app, identifier: "codexbalance.status-item")
    else { throw QAError(description: "status_item_missing") }
    trace("status_item_observed")
    guard let statusFrame = stableFrame(status) else {
        throw QAError(description: "status_frame_not_stable")
    }
    trace("status_frame_stable", statusFrame)

    let outside = CGPoint(
        x: statusFrame.minX > 120 ? 8 : statusFrame.maxX + 160,
        y: statusFrame.midY)
    guard !statusFrame.contains(outside) else { throw QAError(description: "outside_point_invalid") }
    try moveMouse(to: outside)
    trace("cursor_outside_observed", statusFrame)

    let inside = CGPoint(x: statusFrame.midX, y: statusFrame.midY)
    let insideNudge = CGPoint(x: min(statusFrame.maxX - 2, inside.x + 2), y: inside.y)
    func waitForHoverPanel() throws -> Bool {
        if wait(timeout: 0.35, { find(app, identifier: "codexbalance.dashboard.panel") != nil }) {
            return true
        }
        try moveMouse(to: insideNudge)
        trace("cursor_nudged_inside", statusFrame)
        return wait(timeout: 1.65, { find(app, identifier: "codexbalance.dashboard.panel") != nil })
    }
    try moveMouse(to: inside)
    trace("cursor_crossed_inside", statusFrame)
    guard try waitForHoverPanel() else {
        trace("tracking_callback_effect_missing", statusFrame)
        throw QAError(description: "first_hover_panel_missing")
    }
    trace("tracking_callback_effect_observed_first", statusFrame)

    if let panel = find(app, identifier: "codexbalance.dashboard.panel"),
       let panelFrame = frame(panel), panelFrame.contains(outside)
    {
        throw QAError(description: "outside_point_intersects_panel")
    }

    try moveMouse(to: outside)
    trace("cursor_away_observed", statusFrame)
    guard wait(timeout: 2, { find(app, identifier: "codexbalance.dashboard.panel") == nil }) else {
        throw QAError(description: "hover_away_did_not_dismiss")
    }
    trace("hover_away_dismissed", statusFrame)

    try moveMouse(to: inside)
    trace("cursor_recrossed_inside", statusFrame)
    guard try waitForHoverPanel() else {
        trace("tracking_callback_effect_missing_reentry", statusFrame)
        throw QAError(description: "second_hover_panel_missing")
    }
    trace("tracking_callback_effect_observed_reentry", statusFrame)
    print("HOVER_ENTRY_PASS")
}

do {
    try main()
} catch {
    fputs("HOVER_ENTRY_FAIL: \(error)\n", stderr)
    exit(1)
}
