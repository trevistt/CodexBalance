#!/usr/bin/env swift

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import ScreenCaptureKit

var shortcutDriverTraceURL: URL?
var shortcutDriverCycle: Int?
var qaTargetPID: pid_t?

func recordShortcutDriverTrace(_ event: String, fields: [String: String] = [:]) {
    guard let url = shortcutDriverTraceURL else { return }
    var values = fields
    if let shortcutDriverCycle { values["cycle"] = String(shortcutDriverCycle) }
    let details = values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: ";")
    let row = String(format: "%.6f\t%@\t%@\n", Date().timeIntervalSince1970, event, details)
    guard let data = row.data(using: .utf8),
          let handle = try? FileHandle(forWritingTo: url)
    else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}

struct QAError: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw QAError(description: message) }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    attribute(element, name) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func identifier(_ element: AXUIElement) -> String? {
    stringAttribute(element, kAXIdentifierAttribute)
}

func find(_ root: AXUIElement, identifier target: String, depth: Int = 0) -> AXUIElement? {
    if identifier(root) == target { return root }
    guard depth < 18 else { return nil }
    for child in children(root) {
        if let found = find(child, identifier: target, depth: depth + 1) { return found }
    }
    return nil
}

func descendants(_ root: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 18 else { return [] }
    let direct = children(root)
    return direct + direct.flatMap { descendants($0, depth: depth + 1) }
}

func frame(_ element: AXUIElement) -> CGRect? {
    guard let positionRef = attribute(element, kAXPositionAttribute),
          let sizeRef = attribute(element, kAXSizeAttribute),
          CFGetTypeID(positionRef) == AXValueGetTypeID(),
          CFGetTypeID(sizeRef) == AXValueGetTypeID()
    else { return nil }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position),
          AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    else { return nil }
    return CGRect(origin: position, size: size)
}

func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) <= 0.5
        && abs(lhs.minY - rhs.minY) <= 0.5
        && abs(lhs.width - rhs.width) <= 0.5
        && abs(lhs.height - rhs.height) <= 0.5
}

func stableFrame(_ element: AXUIElement, timeout: TimeInterval = 2) -> CGRect? {
    var previous: CGRect?
    var consecutive = 0
    let deadline = Date().addingTimeInterval(timeout)
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

func wait(
    timeout: TimeInterval,
    interval: TimeInterval = 0.08,
    _ predicate: () -> Bool) -> Bool
{
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if predicate() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
    } while Date() < deadline
    return predicate()
}

func moveMouse(to point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func cursorObserved(at point: CGPoint) -> Bool {
    wait(timeout: 0.5, interval: 0.01) {
        guard let current = CGEvent(source: nil)?.location else { return false }
        return hypot(current.x - point.x, current.y - point.y) <= 2
    }
}

func click(at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(40_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    recordShortcutDriverTrace(
        "synthetic.key.posted",
        fields: [
            "keyCode": String(keyCode),
            "command": flags.contains(.maskCommand) ? "true" : "false",
        ])
    let source = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    usleep(40_000)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
}

func press(_ element: AXUIElement) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    try require(result == .success, "AXPress failed: \(result.rawValue)")
}

func supportsPress(_ element: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let actions = names as? [String]
    else { return false }
    return actions.contains(kAXPressAction as String)
}

func firstPressableDescendant(_ element: AXUIElement, depth: Int = 0) -> AXUIElement? {
    if supportsPress(element) { return element }
    guard depth < 8 else { return nil }
    for child in children(element) {
        if let found = firstPressableDescendant(child, depth: depth + 1) { return found }
    }
    return nil
}

func findPressable(_ element: AXUIElement, label: String, depth: Int = 0) -> AXUIElement? {
    let text = [
        stringAttribute(element, kAXTitleAttribute),
        stringAttribute(element, kAXDescriptionAttribute),
        stringAttribute(element, kAXValueAttribute),
    ].compactMap { $0 }.joined(separator: " ")
    if supportsPress(element), text.localizedCaseInsensitiveContains(label) { return element }
    guard depth < 8 else { return nil }
    for child in children(element) {
        if let found = findPressable(child, label: label, depth: depth + 1) { return found }
    }
    return nil
}

func focus(_ element: AXUIElement) {
    _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
}

func focusedUIElement() -> AXUIElement? {
    let systemWide = AXUIElementCreateSystemWide()
    return attribute(systemWide, kAXFocusedUIElementAttribute) as! AXUIElement?
}

func identifierInAncestry(_ element: AXUIElement?, limit: Int = 8) -> String? {
    var current = element
    for _ in 0..<limit {
        guard let node = current else { return nil }
        if let value = identifier(node), !value.isEmpty { return value }
        current = attribute(node, kAXParentAttribute) as! AXUIElement?
    }
    return nil
}

func processPath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard count > 0 else { return nil }
    return String(cString: buffer)
}

func capture(rect quartzRect: CGRect, to url: URL) throws {
    try require(quartzRect.width > 0 && quartzRect.height > 0, "visual checkpoint frame is empty")
    guard #available(macOS 14.0, *), let qaTargetPID else {
        throw QAError(description: "single-window capture requires macOS 14 or later")
    }

    let contentSemaphore = DispatchSemaphore(value: 0)
    var shareableContent: SCShareableContent?
    var shareableContentError: Error?
    SCShareableContent.getExcludingDesktopWindows(
        true,
        onScreenWindowsOnly: true)
    { content, error in
        shareableContent = content
        shareableContentError = error
        contentSemaphore.signal()
    }
    guard contentSemaphore.wait(timeout: .now() + 5) == .success else {
        throw QAError(description: "timed out while listing target windows")
    }
    if let shareableContentError {
        throw QAError(description: "target-window list failed: \(shareableContentError.localizedDescription)")
    }
    let candidates = shareableContent?.windows.filter {
        $0.owningApplication?.processID == qaTargetPID
            && $0.isOnScreen
            && $0.frame.width >= 300
            && $0.frame.height >= 300
    } ?? []
    guard let target = candidates.min(by: { lhs, rhs in
        let lhsScore = abs(lhs.frame.width - quartzRect.width)
            + abs(lhs.frame.height - quartzRect.height)
            + hypot(lhs.frame.midX - quartzRect.midX, lhs.frame.midY - quartzRect.midY) * 0.05
        let rhsScore = abs(rhs.frame.width - quartzRect.width)
            + abs(rhs.frame.height - quartzRect.height)
            + hypot(rhs.frame.midX - quartzRect.midX, rhs.frame.midY - quartzRect.midY) * 0.05
        return lhsScore < rhsScore
    }), target.frame.intersects(quartzRect) else {
        throw QAError(description: "target fixture panel window is unavailable")
    }

    let filter = SCContentFilter(desktopIndependentWindow: target)
    let configuration = SCStreamConfiguration()
    let scale = NSScreen.screens.first(where: { $0.frame.intersects(target.frame) })?.backingScaleFactor ?? 2
    configuration.width = Int(target.frame.width * scale)
    configuration.height = Int(target.frame.height * scale)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true

    let imageSemaphore = DispatchSemaphore(value: 0)
    var capturedImage: CGImage?
    var captureError: Error?
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
        capturedImage = image
        captureError = error
        imageSemaphore.signal()
    }
    guard imageSemaphore.wait(timeout: .now() + 5) == .success else {
        throw QAError(description: "timed out while capturing target fixture panel")
    }
    if let captureError {
        throw QAError(description: "target fixture panel capture failed: \(captureError.localizedDescription)")
    }
    guard let image = capturedImage else {
        throw QAError(description: "target fixture panel capture is unavailable")
    }
    let representation = NSBitmapImageRep(cgImage: image)
    guard representation.pixelsWide > 0,
          representation.pixelsHigh > 0,
          let data = representation.representation(using: .png, properties: [:])
    else { throw QAError(description: "target fixture panel capture is empty") }
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    let storedSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
        .intValue ?? 0
    try require(storedSize > 0, "target fixture panel PNG is empty")
    print(
        "VISUAL_CHECKPOINT_PASS label=\(url.lastPathComponent) " +
        "window=\(target.windowID) pixels=\(representation.pixelsWide)x\(representation.pixelsHigh) " +
        "bytes=\(storedSize)")
}

func panelCaptureRect(status: CGRect, panel: CGRect) -> CGRect {
    status.union(panel).insetBy(dx: -10, dy: -10)
}

func displayBounds(containing rect: CGRect) -> CGRect? {
    var displays = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetDisplaysWithRect(rect, UInt32(displays.count), &displays, &count) == .success,
          count > 0
    else { return nil }
    return CGDisplayBounds(displays[0])
}

func main() throws {
    _ = NSApplication.shared
    let arguments = CommandLine.arguments
    let liveMode = arguments.contains("--live")
    let allowSingleWindow = liveMode || arguments.contains("--allow-single-window")
    let soakSeconds = arguments.first(where: { $0.hasPrefix("--soak-seconds=") })
        .flatMap { Double($0.replacingOccurrences(of: "--soak-seconds=", with: "")) }
    let shortcutCycles = arguments.first(where: { $0.hasPrefix("--shortcut-cycles=") })
        .flatMap { Int($0.replacingOccurrences(of: "--shortcut-cycles=", with: "")) } ?? 0
    let expectedPanelMaxHeight = arguments.first(where: { $0.hasPrefix("--expected-panel-max-height=") })
        .flatMap { Double($0.replacingOccurrences(of: "--expected-panel-max-height=", with: "")) }
    guard let pidIndex = arguments.firstIndex(of: "--pid"),
          arguments.indices.contains(pidIndex + 1),
          let pid = pid_t(arguments[pidIndex + 1]),
          let outputIndex = arguments.firstIndex(of: "--output"),
          arguments.indices.contains(outputIndex + 1)
    else {
        throw QAError(description: "usage: ui_qa_accessibility.swift --pid PID --output DIR [--expected-path PATH]")
    }
    qaTargetPID = pid
    let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
    if let traceArgument = arguments.first(where: { $0.hasPrefix("--shortcut-driver-trace=") }) {
        let path = String(traceArgument.dropFirst("--shortcut-driver-trace=".count))
        shortcutDriverTraceURL = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        recordShortcutDriverTrace("driver.trace.configured")
    }
    if let pathIndex = arguments.firstIndex(of: "--expected-path"),
       arguments.indices.contains(pathIndex + 1)
    {
        try require(processPath(pid: pid) == arguments[pathIndex + 1], "target PID path mismatch")
    }
    try require(AXIsProcessTrusted(), "macOS Accessibility permission is not granted")

    let app = AXUIElementCreateApplication(pid)
    guard wait(timeout: 5, { find(app, identifier: "codexbalance.status-item") != nil }) else {
        throw QAError(description: "status item AX element not found")
    }
    let status = find(app, identifier: "codexbalance.status-item")!
    guard let statusFrame = stableFrame(status) else {
        throw QAError(description: "status item frame did not stabilize")
    }
    try require(statusFrame.width <= 48, "status item exceeds 48pt: \(statusFrame.width)")
    func statusText() -> String {
        stringAttribute(status, kAXDescriptionAttribute)
            ?? stringAttribute(status, kAXTitleAttribute)
            ?? stringAttribute(status, kAXValueAttribute)
            ?? ""
    }
    // Fixture startup publishes a loading state before the deterministic
    // snapshot. Wait for the expected complete meter instead of asserting the
    // transient loading accessibility label.
    let completeStatusAvailable = wait(timeout: 5) {
        let label = statusText()
        if allowSingleWindow {
            return label.contains("OpenAI Codex") && (label.contains("Session") || label.contains("Weekly"))
        }
        return label.contains("OpenAI Codex") && label.contains("Session") && label.contains("Weekly")
    }
    try require(completeStatusAvailable, "status AX label did not publish a complete quota window: \(statusText())")
    let statusLabel = statusText()
    try require(statusLabel.contains("OpenAI Codex"), "status AX label lacks provider")
    if allowSingleWindow {
        try require(
            statusLabel.contains("Session") || statusLabel.contains("Weekly"),
            "status AX label lacks a complete quota window role")
    } else {
        try require(statusLabel.contains("Session"), "status AX label lacks Session role")
        try require(statusLabel.contains("Weekly"), "status AX label lacks Weekly role")
    }

    let outsideStatus = CGPoint(
        x: statusFrame.minX > 120 ? 8 : statusFrame.maxX + 160,
        y: statusFrame.midY)
    try require(!statusFrame.contains(outsideStatus), "hover preflight outside point intersects status item")
    moveMouse(to: outsideStatus)
    try require(cursorObserved(at: outsideStatus), "hover preflight did not observe cursor outside status item")
    moveMouse(to: CGPoint(x: statusFrame.midX, y: statusFrame.midY))
    try require(
        cursorObserved(at: CGPoint(x: statusFrame.midX, y: statusFrame.midY)),
        "hover preflight did not observe cursor inside status item")
    guard wait(timeout: 3, { find(app, identifier: "codexbalance.dashboard.panel") != nil }) else {
        throw QAError(description: "hover did not open dashboard")
    }
    let panel = find(app, identifier: "codexbalance.dashboard.panel")!
    _ = AXUIElementPerformAction(panel, kAXRaiseAction as CFString)
    usleep(180_000)
    guard let hoverFrame = frame(panel) else { throw QAError(description: "hover panel frame missing") }
    try capture(
        rect: panelCaptureRect(status: statusFrame, panel: hoverFrame),
        to: output.appendingPathComponent("apple-material-hover.png"))
    print("PASS hover opens the real packaged dashboard")

    // Exercise the real menu-bar mouse path, not merely AXPress. This gives
    // the accessory application the same keyboard ownership as a user click.
    click(at: CGPoint(x: statusFrame.midX, y: statusFrame.midY))
    usleep(250_000)
    guard let clickPanel = find(app, identifier: "codexbalance.dashboard.panel"),
          let clickFrame = frame(clickPanel)
    else { throw QAError(description: "click dashboard missing") }
    print("GEOMETRY status=\(statusFrame) hover=\(hoverFrame) click=\(clickFrame)")
    try require(abs(clickFrame.minX - hoverFrame.minX) <= 2, "panel x jumped after click")
    try require(abs(clickFrame.maxY - hoverFrame.maxY) <= 2, "panel top anchor jumped after click")
    try require(clickFrame.width >= 374 && clickFrame.width <= 384, "panel width is outside the V2 material target: \(clickFrame.width)")
    if let statusDisplay = displayBounds(containing: statusFrame) {
        try require(
            statusDisplay == displayBounds(containing: clickFrame),
            "panel and status item are on different displays")
        try require(
            clickFrame.minX <= statusFrame.midX && statusFrame.midX <= clickFrame.maxX,
            "panel is not horizontally anchored to the triggering status item")
        try require(
            abs(clickFrame.minY - statusFrame.maxY) <= 20,
            "panel is not vertically adjacent to the triggering status item")
        print("PASS panel is adjacent to the triggering status item on the same display")
    } else {
        try require(displayBounds(containing: clickFrame) != nil, "panel is not visible on an active display")
        print("UNVERIFIED status item AX frame is outside active displays; deterministic multi-display checks cover selection")
    }
    if let expectedPanelMaxHeight {
        try require(
            clickFrame.height <= expectedPanelMaxHeight + 2,
            "panel exceeds fixture height constraint: \(clickFrame.height)")
        print("PASS panel respects \(Int(expectedPanelMaxHeight))pt fixture height constraint")
    }
    print("PASS AXPress activates the real menu bar item without moving the panel")

    if shortcutCycles > 0 {
        // Normalize the hover-opened fixture into the same interactive panel
        // state required by documented keyboard shortcuts. One AXPress either
        // makes the hover panel interactive or dismisses an already-interactive
        // panel; only the latter case needs one more AXPress to reopen it.
        try press(status)
        if wait(timeout: 0.4, { find(app, identifier: "codexbalance.dashboard.panel") == nil }) {
            try press(status)
            try require(
                wait(timeout: 1, { find(app, identifier: "codexbalance.dashboard.panel") != nil }),
                "diagnostic panel did not reopen interactively")
        }
        guard let diagnosticPanel = find(app, identifier: "codexbalance.dashboard.panel"),
              let diagnosticFrame = frame(diagnosticPanel)
        else { throw QAError(description: "diagnostic interactive panel is unavailable") }
        focus(diagnosticPanel)
        click(at: CGPoint(x: diagnosticFrame.midX, y: diagnosticFrame.midY))
        guard let refresh = find(app, identifier: "codexbalance.dashboard.refresh") else {
            throw QAError(description: "diagnostic Refresh control is unavailable")
        }
        focus(refresh)
        var acknowledged = 0
        for cycle in 1...shortcutCycles {
            shortcutDriverCycle = cycle
            recordShortcutDriverTrace("cycle.started")
            key(15, flags: .maskCommand)
            let didAcknowledge = wait(timeout: 0.25, interval: 0.005) {
                let value = find(app, identifier: "codexbalance.dashboard.refresh")
                    .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
                    ?? ""
                return value.localizedCaseInsensitiveContains("refreshing")
                    || value.localizedCaseInsensitiveContains("refresh unavailable")
                    || value.localizedCaseInsensitiveContains("already in progress")
            }
            recordShortcutDriverTrace(
                "cycle.observed",
                fields: ["acknowledged": didAcknowledge ? "true" : "false"])
            if didAcknowledge {
                acknowledged += 1
                _ = wait(timeout: 3, interval: 0.02) {
                    let value = find(app, identifier: "codexbalance.dashboard.refresh")
                        .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
                        ?? ""
                    return value == "Refresh"
                }
            }
        }
        shortcutDriverCycle = nil
        print("SHORTCUT_DIAGNOSTIC cycles=\(shortcutCycles) acknowledged=\(acknowledged)")
        try require(
            acknowledged == shortcutCycles,
            "Command-R targeted matrix acknowledged \(acknowledged)/\(shortcutCycles)")
        print("SHORTCUT_DIAGNOSTIC_PASS cycles=\(shortcutCycles)")
        return
    }

    let required = [
        "codexbalance.dashboard.header",
        "codexbalance.dashboard.runway",
        "codexbalance.dashboard.body-scroll",
        "codexbalance.dashboard.quota",
        "codexbalance.dashboard.observation",
        "codexbalance.dashboard.analytics",
        "codexbalance.dashboard.today-vs-normal",
        "codexbalance.dashboard.recent-work",
        "codexbalance.dashboard.diagnostics",
        "codexbalance.dashboard.footer",
        "codexbalance.dashboard.refresh",
        "codexbalance.dashboard.pin",
        "codexbalance.dashboard.cadence",
        "codexbalance.dashboard.quit",
    ]
    for target in required {
        try require(find(app, identifier: target) != nil, "missing AX element \(target)")
    }
    try require(find(app, identifier: "codexbalance.tab.overview") == nil, "retired tab remains")
    try require(find(app, identifier: "codexbalance.provider-order") == nil, "retired order control remains")

    for target in [
        "codexbalance.dashboard.activity-range",
        "codexbalance.dashboard.refresh",
        "codexbalance.dashboard.pin",
        "codexbalance.dashboard.cadence",
        "codexbalance.dashboard.quit",
    ] {
        guard let element = find(app, identifier: target), let targetFrame = frame(element) else {
            throw QAError(description: "control frame missing: \(target)")
        }
        try require(targetFrame.width >= 28 && targetFrame.height >= 28, "control below 28pt: \(target) \(targetFrame)")
    }

    guard let analytics = find(app, identifier: "codexbalance.dashboard.analytics") else {
        throw QAError(description: "analytics AX container is unavailable")
    }
    let histogramValues = descendants(analytics).filter {
        (identifier($0) ?? "").hasPrefix("codexbalance.dashboard.histogram.")
    }
    try require(histogramValues.count >= 7, "histogram did not expose dated accessibility values")
    for value in histogramValues {
        let role = stringAttribute(value, kAXRoleAttribute) ?? ""
        let spoken = [
            stringAttribute(value, kAXTitleAttribute),
            stringAttribute(value, kAXDescriptionAttribute),
            stringAttribute(value, kAXValueAttribute),
        ].compactMap { $0 }.joined(separator: " ")
        try require(role != (kAXUnknownRole as String), "histogram value has AXUnknown role")
        try require(
            spoken.localizedCaseInsensitiveContains("tokens") || spoken.localizedCaseInsensitiveContains("activity"),
            "histogram value lacks an estimated token summary")
    }
    print("PASS histogram exposes \(histogramValues.count) dated token summaries")

    guard let header = find(app, identifier: "codexbalance.dashboard.header"),
          let footer = find(app, identifier: "codexbalance.dashboard.footer"),
          let body = find(app, identifier: "codexbalance.dashboard.body-scroll"),
          let headerBefore = frame(header),
          let footerBefore = frame(footer),
          let bodyFrame = frame(body)
    else { throw QAError(description: "fixed region frames missing") }
    moveMouse(to: CGPoint(x: bodyFrame.midX, y: bodyFrame.midY))
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -260, wheel2: 0, wheel3: 0)?
        .post(tap: .cghidEventTap)
    usleep(250_000)
    try require(frame(header) == headerBefore, "header moved during body scroll")
    try require(frame(footer) == footerBefore, "footer moved during body scroll")
    try capture(
        rect: panelCaptureRect(status: statusFrame, panel: clickFrame),
        to: output.appendingPathComponent("apple-material-scrolled.png"))
    print("PASS body-only scroll keeps header and footer fixed")

    if let range = find(app, identifier: "codexbalance.dashboard.activity-range") {
        try press(range)
        usleep(120_000)
        key(53)
    } else {
        throw QAError(description: "activity range menu is unavailable")
    }
    print("PASS compact activity range menu opens and dismisses")

    guard let details = find(app, identifier: "codexbalance.dashboard.diagnostics") else {
        throw QAError(description: "Details disclosure is unavailable")
    }
    var detailsFrame = frame(details)
    for attempt in 0..<5 where detailsFrame?.intersects(bodyFrame) != true {
        print("DETAILS_SCROLL attempt=\(attempt) frame=\(String(describing: detailsFrame))")
        moveMouse(to: CGPoint(x: bodyFrame.midX, y: bodyFrame.midY))
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -420, wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
        usleep(160_000)
        detailsFrame = frame(details)
    }
    print("DETAILS_FRAME final=\(String(describing: detailsFrame)) body=\(bodyFrame)")
    guard let collapsedDetailsFrame = detailsFrame, collapsedDetailsFrame.intersects(bodyFrame) else {
        throw QAError(description: "Details disclosure could not be scrolled into view")
    }
    guard let detailsToggle = find(app, identifier: "codexbalance.dashboard.details-toggle") else {
        throw QAError(description: "Details toggle is unavailable")
    }
    guard let detailsToggleFrame = frame(detailsToggle) else {
        throw QAError(description: "Details toggle frame is unavailable")
    }
    try require(
        detailsToggleFrame.width >= 28 && detailsToggleFrame.height >= 28,
        "Details toggle is below 28pt: \(detailsToggleFrame)")
    try press(detailsToggle)
    try require(
        wait(timeout: 1, { find(app, identifier: "codexbalance.dashboard.copy-diagnostics") != nil }),
        "Details did not reveal comprehensive diagnostics")
    guard let copyDiagnostics = find(app, identifier: "codexbalance.dashboard.copy-diagnostics"),
          let copyFrame = frame(copyDiagnostics)
    else { throw QAError(description: "Copy diagnostics control is unavailable") }
    try require(copyFrame.width >= 28 && copyFrame.height >= 28, "Copy diagnostics is below 28pt: \(copyFrame)")
    try capture(
        rect: panelCaptureRect(status: statusFrame, panel: clickFrame),
        to: output.appendingPathComponent("apple-material-details.png"))
    try press(find(app, identifier: "codexbalance.dashboard.details-toggle")!)
    print("PASS Details disclosure preserves comprehensive diagnostics")

    let refresh = find(app, identifier: "codexbalance.dashboard.refresh")!
    let refreshFeedbackStarted = Date()
    try press(refresh)
    guard wait(timeout: 0.25, interval: 0.005, {
        let value = find(app, identifier: "codexbalance.dashboard.refresh")
            .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
            ?? ""
        return value.localizedCaseInsensitiveContains("refreshing")
    }) else { throw QAError(description: "Refresh did not expose feedback") }
    let refreshFeedbackMS = Date().timeIntervalSince(refreshFeedbackStarted) * 1_000
    try require(refreshFeedbackMS <= 50, "Refresh feedback exceeded 50ms: \(Int(refreshFeedbackMS))ms")
    usleep(60_000)
    try capture(
        rect: panelCaptureRect(status: statusFrame, panel: clickFrame),
        to: output.appendingPathComponent("apple-material-refreshing.png"))
    guard wait(timeout: 4, {
        let value = find(app, identifier: "codexbalance.dashboard.refresh")
            .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
            ?? ""
        return !value.localizedCaseInsensitiveContains("refreshing")
    }) else { throw QAError(description: "Refresh did not complete") }
    print("PASS Refresh provides feedback in \(Int(refreshFeedbackMS))ms and completes")

    func pinLabel() -> String {
        let element = find(app, identifier: "codexbalance.dashboard.pin")
        return element.flatMap {
            stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute)
        } ?? ""
    }

    // Pin is a persisted user preference. Normalize the fixture journey to
    // unpinned so a prior real run cannot invert this interaction assertion.
    if pinLabel().localizedCaseInsensitiveContains("unpin") {
        try press(find(app, identifier: "codexbalance.dashboard.pin")!)
        try require(wait(timeout: 1, { !pinLabel().localizedCaseInsensitiveContains("unpin") }), "existing pinned state did not clear")
    }

    if let keyboardPanel = find(app, identifier: "codexbalance.dashboard.panel"),
       let keyboardFrame = frame(keyboardPanel)
    {
        focus(keyboardPanel)
        click(at: CGPoint(x: keyboardFrame.midX, y: keyboardFrame.midY))
    }
    let keyboardOrder = [
        "codexbalance.dashboard.refresh",
        "codexbalance.dashboard.pin",
        "codexbalance.dashboard.cadence",
        "codexbalance.dashboard.quit",
    ]
    guard let firstKeyboardControl = find(app, identifier: keyboardOrder[0]) else {
        throw QAError(description: "keyboard traversal start control is unavailable")
    }
    focus(firstKeyboardControl)
    try require(
        wait(timeout: 1, { identifierInAncestry(focusedUIElement()) == keyboardOrder[0] }),
        "Refresh did not accept keyboard focus")
    for expected in keyboardOrder.dropFirst() {
        key(48)
        try require(
            wait(timeout: 1, { identifierInAncestry(focusedUIElement()) == expected }),
            "Tab focus order did not reach \(expected); focused=\(identifierInAncestry(focusedUIElement()) ?? "none")")
    }
    key(48, flags: .maskShift)
    try require(
        wait(timeout: 1, { identifierInAncestry(focusedUIElement()) == "codexbalance.dashboard.cadence" }),
        "Shift-Tab did not reverse focus to Smart Refresh")
    if let keyboardPanel = find(app, identifier: "codexbalance.dashboard.panel"),
       let keyboardFrame = frame(keyboardPanel)
    {
        try capture(
            rect: panelCaptureRect(status: statusFrame, panel: keyboardFrame),
            to: output.appendingPathComponent("apple-material-keyboard-focus.png"))
    }
    guard let keyboardPin = find(app, identifier: "codexbalance.dashboard.pin") else {
        throw QAError(description: "Pin control is unavailable for keyboard activation")
    }
    focus(keyboardPin)
    key(49)
    try require(
        wait(timeout: 1, { pinLabel().localizedCaseInsensitiveContains("unpin") }),
        "Space did not activate Pin")
    key(49)
    try require(
        wait(timeout: 1, { !pinLabel().localizedCaseInsensitiveContains("unpin") }),
        "Space did not activate Unpin")
    guard let keyboardRefresh = find(app, identifier: "codexbalance.dashboard.refresh") else {
        throw QAError(description: "Refresh control is unavailable for keyboard activation")
    }
    focus(keyboardRefresh)
    key(36)
    try require(
        wait(timeout: 0.25, interval: 0.005, {
            let value = find(app, identifier: "codexbalance.dashboard.refresh")
                .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
                ?? ""
            return value.localizedCaseInsensitiveContains("refreshing")
        }),
        "Return did not activate Refresh")
    try require(wait(timeout: 4, {
        let value = find(app, identifier: "codexbalance.dashboard.refresh")
            .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
            ?? ""
        return !value.localizedCaseInsensitiveContains("refreshing")
    }), "keyboard Refresh did not complete")
    key(15, flags: .maskCommand)
    try require(
        wait(timeout: 0.25, interval: 0.005, {
            let value = find(app, identifier: "codexbalance.dashboard.refresh")
                .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
                ?? ""
            return value.localizedCaseInsensitiveContains("refreshing")
        }),
        "Command-R did not activate Refresh")
    try require(wait(timeout: 4, {
        let value = find(app, identifier: "codexbalance.dashboard.refresh")
            .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
            ?? ""
        return !value.localizedCaseInsensitiveContains("refreshing")
    }), "Command-R refresh did not complete")
    print("PASS Tab, Shift-Tab, Space, Return, and Command-R keyboard paths")

    let pin = find(app, identifier: "codexbalance.dashboard.pin")!
    try press(pin)
    try require(wait(timeout: 1, { pinLabel().localizedCaseInsensitiveContains("unpin") }), "Pin action did not enter pinned state")
    moveMouse(to: CGPoint(x: clickFrame.minX - 80, y: clickFrame.minY - 80))
    usleep(550_000)
    try require(find(app, identifier: "codexbalance.dashboard.panel") != nil, "Pin did not preserve panel")
    try capture(
        rect: panelCaptureRect(status: statusFrame, panel: clickFrame),
        to: output.appendingPathComponent("apple-material-pinned.png"))
    if let soakSeconds, soakSeconds > 0 {
        print("SOAK_BEGIN seconds=\(Int(soakSeconds))")
        let expectedProcessPath = processPath(pid: pid)
        let pinnedPanel = find(app, identifier: "codexbalance.dashboard.panel")!
        let expectedRightAnchorDelta = clickFrame.maxX - statusFrame.maxX
        let expectedTopAnchorDelta = clickFrame.minY - statusFrame.maxY
        let deadline = Date().addingTimeInterval(soakSeconds)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(min(5, deadline.timeIntervalSinceNow)))
            let reason: String?
            let currentApp = AXUIElementCreateApplication(pid)
            let currentStatus = find(currentApp, identifier: "codexbalance.status-item")
            let currentPanel = find(currentApp, identifier: "codexbalance.dashboard.panel")
            let currentStatusFrame = currentStatus.flatMap(frame)
            let currentPanelFrame = currentPanel.flatMap(frame)
            if kill(pid, 0) != 0 {
                reason = "target PID exited"
            } else if processPath(pid: pid) != expectedProcessPath {
                reason = "target executable identity changed"
            } else if currentStatus == nil || currentStatusFrame == nil {
                reason = "expected status item disappeared"
            } else if currentPanel == nil || currentPanelFrame == nil {
                reason = "pinned panel disappeared"
            } else if !(attribute(currentApp, kAXWindowsAttribute) as? [AXUIElement] ?? [])
                .contains(where: { identifier($0) == identifier(pinnedPanel) })
            {
                reason = "pinned panel is absent from the application window list"
            } else if let statusFrame = currentStatusFrame,
                      let panelFrame = currentPanelFrame,
                      abs((panelFrame.maxX - statusFrame.maxX) - expectedRightAnchorDelta) > 2
                        || abs((panelFrame.minY - statusFrame.maxY) - expectedTopAnchorDelta) > 2
            {
                reason = "pinned panel anchor drifted"
            } else if let panelFrame = currentPanelFrame,
                      let screen = displayBounds(containing: panelFrame),
                      !screen.insetBy(dx: -1, dy: -1).contains(panelFrame)
            {
                reason = "pinned panel left the visible display bounds"
            } else if displayBounds(containing: currentPanelFrame ?? .zero) == nil {
                reason = "pinned panel is not visible on a display"
            } else if [
                "codexbalance.dashboard.header",
                "codexbalance.dashboard.runway",
                "codexbalance.dashboard.footer",
            ].contains(where: { target in
                guard let element = find(currentApp, identifier: target),
                      let elementFrame = frame(element),
                      let panelFrame = currentPanelFrame
                else { return true }
                return elementFrame.width <= 0 || elementFrame.height <= 0 || !elementFrame.intersects(panelFrame)
            }) {
                reason = "pinned panel lost nonblank header, runway, or footer content"
            } else {
                reason = nil
            }
            if let reason {
                try capture(
                    rect: currentPanelFrame ?? clickFrame,
                    to: output.appendingPathComponent("apple-material-soak-fail-fast.png"))
                throw QAError(description: "soak fail-fast elapsed=\(Int(soakSeconds - max(0, deadline.timeIntervalSinceNow)))s: \(reason)")
            }
        }
        try capture(
            rect: panelCaptureRect(status: statusFrame, panel: clickFrame),
            to: output.appendingPathComponent("apple-material-soak.png"))
        print("SOAK_PASS seconds=\(Int(soakSeconds))")
    } else if let soakSeconds {
        print("SOAK_PASS seconds=\(Int(soakSeconds))")
    }
    // AppKit can refresh an accessory application's AX child tree while a
    // long pinned panel remains onscreen. Reacquire the application root and
    // make the post-soak control assertion explicit rather than crashing.
    let postSoakApp = AXUIElementCreateApplication(pid)
    guard let postSoakStatus = find(postSoakApp, identifier: "codexbalance.status-item"),
          let postSoakStatusFrame = frame(postSoakStatus)
    else { throw QAError(description: "status item is unavailable after soak") }
    guard let unpin = wait(timeout: 2, { find(postSoakApp, identifier: "codexbalance.dashboard.pin") != nil })
        ? find(postSoakApp, identifier: "codexbalance.dashboard.pin")
        : nil
    else {
        throw QAError(description: "pinned dashboard Pin control is unavailable after soak")
    }
    try press(unpin)
    moveMouse(to: CGPoint(x: clickFrame.minX - 80, y: clickFrame.minY - 80))
    guard wait(timeout: 2, { find(postSoakApp, identifier: "codexbalance.dashboard.panel") == nil }) else {
        throw QAError(description: "Unpin did not restore auto-dismiss")
    }
    print("PASS Pin and Unpin preserve expected dismissal behavior")

    if liveMode {
        let finalStatus = stringAttribute(postSoakStatus, kAXDescriptionAttribute)
            ?? stringAttribute(postSoakStatus, kAXTitleAttribute)
            ?? stringAttribute(postSoakStatus, kAXValueAttribute)
            ?? "unavailable"
        print("LIVE_STATUS \(finalStatus)")
        print("UI_QA_PASS status_width=\(Int(statusFrame.width)) output=\(output.path)")
        return
    }

    moveMouse(to: CGPoint(x: postSoakStatusFrame.midX, y: postSoakStatusFrame.midY))
    try require(wait(timeout: 2, { find(postSoakApp, identifier: "codexbalance.dashboard.panel") != nil }), "reopen failed")
    try press(postSoakStatus)
    usleep(180_000)
    // Accessory menu-bar apps may not report `isActive` even when their panel
    // owns keyboard focus. The following Command-P/Escape assertions verify
    // the observable keyboard behavior directly.
    if let keyboardPanel = find(postSoakApp, identifier: "codexbalance.dashboard.panel"),
       let keyboardFrame = frame(keyboardPanel)
    {
        focus(keyboardPanel)
        // Give the accessory panel real input ownership before synthesizing
        // its documented shortcut; AX focus alone is not sufficient on every
        // macOS status-item activation path.
        click(at: CGPoint(x: keyboardFrame.midX, y: keyboardFrame.midY))
    }
    usleep(120_000)

    let postKeyboardOrder = [
        "codexbalance.dashboard.refresh",
        "codexbalance.dashboard.pin",
        "codexbalance.dashboard.cadence",
        "codexbalance.dashboard.quit",
    ]
    guard let postFirstControl = find(postSoakApp, identifier: postKeyboardOrder[0]) else {
        throw QAError(description: "post-soak keyboard traversal start control is unavailable")
    }
    focus(postFirstControl)
    try require(
        wait(timeout: 1, { identifierInAncestry(focusedUIElement()) == postKeyboardOrder[0] }),
        "post-soak Refresh did not accept keyboard focus")
    for expected in postKeyboardOrder.dropFirst() {
        key(48)
        try require(
            wait(timeout: 1, { identifierInAncestry(focusedUIElement()) == expected }),
            "post-soak Tab focus order did not reach \(expected)")
    }
    key(48, flags: .maskShift)
    try require(
        wait(timeout: 1, { identifierInAncestry(focusedUIElement()) == "codexbalance.dashboard.cadence" }),
        "post-soak Shift-Tab did not reverse focus")
    if let keyboardPanel = find(postSoakApp, identifier: "codexbalance.dashboard.panel"),
       let keyboardFrame = frame(keyboardPanel)
    {
        try capture(
            rect: panelCaptureRect(status: postSoakStatusFrame, panel: keyboardFrame),
            to: output.appendingPathComponent("apple-material-post-soak-keyboard-focus.png"))
    }

    func postSoakPinLabel() -> String {
        let element = find(postSoakApp, identifier: "codexbalance.dashboard.pin")
        return element.flatMap {
            stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute)
        } ?? ""
    }
    guard let postKeyboardPin = find(postSoakApp, identifier: "codexbalance.dashboard.pin") else {
        throw QAError(description: "post-soak Pin control is unavailable")
    }
    focus(postKeyboardPin)
    key(49)
    try require(
        wait(timeout: 1, { postSoakPinLabel().localizedCaseInsensitiveContains("unpin") }),
        "post-soak Space did not activate Pin")
    key(49)
    try require(
        wait(timeout: 1, { !postSoakPinLabel().localizedCaseInsensitiveContains("unpin") }),
        "post-soak Space did not activate Unpin")

    func refreshLabel() -> String {
        find(postSoakApp, identifier: "codexbalance.dashboard.refresh")
            .flatMap { stringAttribute($0, kAXTitleAttribute) ?? stringAttribute($0, kAXDescriptionAttribute) }
            ?? ""
    }
    func refreshAttemptWasAcknowledged() -> Bool {
        let label = refreshLabel()
        return label.localizedCaseInsensitiveContains("refreshing")
            || label.localizedCaseInsensitiveContains("refresh unavailable")
            || label.localizedCaseInsensitiveContains("already in progress")
    }
    func waitForRefreshAttemptToSettle() -> Bool {
        wait(timeout: 4, { refreshLabel() == "Refresh" })
    }
    guard let postKeyboardRefresh = find(postSoakApp, identifier: "codexbalance.dashboard.refresh") else {
        throw QAError(description: "post-soak Refresh control is unavailable")
    }
    focus(postKeyboardRefresh)
    key(36)
    try require(
        wait(timeout: 0.25, interval: 0.005, refreshAttemptWasAcknowledged),
        "post-soak Return did not produce Refresh feedback")
    try require(waitForRefreshAttemptToSettle(), "post-soak Return feedback did not settle")
    // A status-item accessory panel can relinquish key-window ownership after
    // handling a focused button action. Reassert real panel input ownership
    // before testing the app-level Command-R shortcut after a long soak.
    if let keyboardPanel = find(postSoakApp, identifier: "codexbalance.dashboard.panel"),
       let keyboardFrame = frame(keyboardPanel)
    {
        focus(keyboardPanel)
        click(at: CGPoint(x: keyboardFrame.midX, y: keyboardFrame.midY))
    }
    key(15, flags: .maskCommand)
    try require(
        wait(timeout: 0.25, interval: 0.005, refreshAttemptWasAcknowledged),
        "post-soak Command-R did not produce Refresh feedback")
    try require(waitForRefreshAttemptToSettle(), "post-soak Command-R feedback did not settle")
    print("PASS post-soak Tab, Shift-Tab, Space, Return, and Command-R paths")

    key(35, flags: .maskCommand)
    usleep(180_000)
    moveMouse(to: CGPoint(x: hoverFrame.minX - 60, y: hoverFrame.minY - 60))
    usleep(500_000)
    try require(find(postSoakApp, identifier: "codexbalance.dashboard.panel") != nil, "Command-P did not pin")
    key(35, flags: .maskCommand)
    key(53)
    try require(wait(timeout: 2, { find(postSoakApp, identifier: "codexbalance.dashboard.panel") == nil }), "Escape did not dismiss")
    print("PASS keyboard Pin and Escape dismissal")
    print("UI_QA_PASS status_width=\(Int(statusFrame.width)) output=\(output.path)")
}

do {
    try main()
} catch {
    fputs("UI_QA_FAIL: \(error)\n", stderr)
    exit(1)
}
