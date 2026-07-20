import CoreServices
import Foundation

/// Watches Codex log trees through FSEvents. Unlike vnode watches on the root,
/// FSEvents reports writes below `sessions/YYYY/MM/DD` and newly-created child
/// directories without opening or parsing any log content.
public final class LocalUsageActivityMonitor: @unchecked Sendable {
    private let roots: [URL]
    private let onActivity: @Sendable () -> Void
    private let queue = DispatchQueue(label: "CodexBalance.LocalUsageActivityMonitor", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(roots: [URL], onActivity: @escaping @Sendable () -> Void) {
        self.roots = roots
        self.onActivity = onActivity
    }

    public func start() {
        self.stop()
        let paths = self.roots
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagNoDefer |
                kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags)
        else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, self.queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream = self.stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { self.stop() }

    private static let callback: FSEventStreamCallback = { _, info, eventCount, _, _, _ in
        guard eventCount > 0, let info else { return }
        let monitor = Unmanaged<LocalUsageActivityMonitor>.fromOpaque(info).takeUnretainedValue()
        monitor.onActivity()
    }
}
