import AppKit
import CoreGraphics
import CodexBalanceCore

@MainActor
final class UserPresenceMonitor {
    private let idleThreshold: TimeInterval
    private let onChange: (UserPresenceState) -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var idleTimer: Timer?
    private var isSystemAsleep = false
    private var isDisplayAsleep = false
    private var isLocked = false
    private var isScreenSaverActive = false
    private var lastState: UserPresenceState?

    init(
        idleThreshold: TimeInterval = 10 * 60,
        onChange: @escaping (UserPresenceState) -> Void)
    {
        self.idleThreshold = idleThreshold
        self.onChange = onChange
    }

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        self.workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isSystemAsleep = true
                        self?.emitCurrentState()
                    }
                },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isSystemAsleep = false
                        self?.emitCurrentState()
                    }
                },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidSleepNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isDisplayAsleep = true
                        self?.emitCurrentState()
                    }
                },
            workspaceCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isDisplayAsleep = false
                        self?.emitCurrentState()
                    }
                },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isLocked = true
                        self?.emitCurrentState()
                    }
                },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isLocked = false
                        self?.emitCurrentState()
                    }
                },
        ]

        let distributedCenter = DistributedNotificationCenter.default()
        self.distributedObservers = [
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isLocked = true
                        self?.emitCurrentState()
                    }
                },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isLocked = false
                        self?.emitCurrentState()
                    }
                },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstart"),
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isScreenSaverActive = true
                        self?.emitCurrentState()
                    }
                },
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screensaver.didstop"),
                object: nil,
                queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.isScreenSaverActive = false
                        self?.emitCurrentState()
                    }
                },
        ]

        self.idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.emitCurrentState()
            }
        }
        self.emitCurrentState()
    }

    func stop() {
        for observer in self.workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        self.workspaceObservers = []
        let distributedCenter = DistributedNotificationCenter.default()
        for observer in self.distributedObservers {
            distributedCenter.removeObserver(observer)
        }
        self.distributedObservers = []
        self.idleTimer?.invalidate()
        self.idleTimer = nil
    }

    private func emitCurrentState() {
        let state = self.currentState()
        guard state != self.lastState else { return }
        self.lastState = state
        self.onChange(state)
    }

    private func currentState() -> UserPresenceState {
        if self.isSystemAsleep { return .suspended }
        if self.isDisplayAsleep { return .asleep }
        if self.isLocked { return .locked }
        if self.isScreenSaverActive { return .screensaver }
        if Self.idleSeconds() >= self.idleThreshold { return .idle }
        return .active
    }

    private static func idleSeconds() -> TimeInterval {
        guard let anyEvent = CGEventType(rawValue: UInt32.max) else {
            return 0
        }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyEvent)
    }
}
