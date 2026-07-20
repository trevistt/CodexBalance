import Foundation

public struct LocalUsageIndexResult: Sendable {
    public let snapshot: LocalUsageAnalyticsSnapshot
    public let payloadBytesRead: Int
    public let reusedUnchangedIndex: Bool
}

/// A CodexBalance-owned, metadata-only index. It persists no source paths,
/// prompts, messages, titles, or raw JSON. Appends are read from the prior
/// byte offset; rotation, truncation, or in-place replacement rebuilds only
/// that file.
public struct LocalUsageIndex: Sendable {
    private static let version = 2
    private let url: URL

    private struct FileStamp: Codable, Equatable, Sendable {
        let key: String
        let fileID: String?
        let bytes: Int64
        let modifiedAt: TimeInterval
    }

    private struct IndexedFile: Codable, Sendable {
        let stamp: FileStamp
        let scannerState: LocalUsageLogScanner.FileScanState
        let records: [LocalUsageLogScanner.Record]
    }

    private struct State: Codable, Sendable {
        let version: Int
        let timezoneID: String
        let files: [IndexedFile]
    }

    public init(url: URL? = nil) {
        self.url = url ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/CodexBalance/local-usage-index-v1.json")
    }

    public func refresh(
        roots: [URL],
        now: Date,
        options: LocalUsageLogScanner.Options = .init()) throws -> LocalUsageIndexResult
    {
        let scannedFiles = self.files(roots: roots, maxFiles: options.maxFiles)
        guard !scannedFiles.isEmpty else { throw LocalUsageAnalyticsError.noLogsFound }
        let oldState = self.load().flatMap { state in
            state.version == Self.version && state.timezoneID == TimeZone.current.identifier ? state : nil
        }
        let oldFiles = Dictionary(uniqueKeysWithValues: (oldState?.files ?? []).map { ($0.stamp.key, $0) })
        var nextFiles: [IndexedFile] = []
        var payloadBytesRead = 0

        for (fileURL, stamp) in scannedFiles {
            try Task.checkCancellation()
            let old = oldFiles[stamp.key]
            if let old, old.stamp == stamp {
                nextFiles.append(old)
                continue
            }

            let appended = old.flatMap { prior in
                stamp.bytes > prior.stamp.bytes && stamp.modifiedAt >= prior.stamp.modifiedAt ? prior : nil
            }
            let result: LocalUsageLogScanner.FileScanResult
            if let appended {
                result = try LocalUsageLogScanner.scanFile(
                    fileURL: fileURL,
                    startingAt: UInt64(appended.stamp.bytes),
                    state: appended.scannerState,
                    options: options)
                nextFiles.append(IndexedFile(
                    stamp: stamp,
                    scannerState: result.state,
                    records: self.trim(appended.records + result.records, now: now)))
            } else {
                result = try LocalUsageLogScanner.scanFile(fileURL: fileURL, options: options)
                nextFiles.append(IndexedFile(
                    stamp: stamp,
                    scannerState: result.state,
                    records: self.trim(result.records, now: now)))
            }
            payloadBytesRead += result.bytesRead
        }

        let records = nextFiles.flatMap(\.records)
        let snapshot = try LocalUsageLogScanner.snapshot(records: records, now: now, options: options)
        let state = State(version: Self.version, timezoneID: TimeZone.current.identifier, files: nextFiles)
        if payloadBytesRead > 0 || oldState == nil,
           let data = try? JSONEncoder().encode(state)
        {
            try? PrivateFileStore.write(data, to: self.url)
        }
        return LocalUsageIndexResult(
            snapshot: snapshot,
            payloadBytesRead: payloadBytesRead,
            reusedUnchangedIndex: payloadBytesRead == 0)
    }

    public func invalidate() { try? FileManager.default.removeItem(at: self.url) }

    private func load() -> State? {
        guard let data = PrivateFileStore.read(at: self.url) else { return nil }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func files(roots: [URL], maxFiles: Int) -> [(URL, FileStamp)] {
        LocalUsageLogScanner.jsonlFiles(roots: roots, maxFiles: maxFiles).compactMap { fileURL in
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]) else { return nil }
            return (fileURL, FileStamp(
                key: Self.nonIdentifyingKey(fileURL.path),
                fileID: values.fileResourceIdentifier.map { String(describing: $0) },
                bytes: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }.sorted { $0.1.key < $1.1.key }
    }

    private func trim(_ records: [LocalUsageLogScanner.Record], now: Date) -> [LocalUsageLogScanner.Record] {
        let cutoff = now.addingTimeInterval(-31 * 86_400)
        return records.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp < $1.timestamp }
    }

    private static func nonIdentifyingKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
