import Darwin
import Foundation

enum PrivateFileStore {
    static let maximumSize = 1_048_576

    static func read(at url: URL) -> Data? {
        var pathStatus = stat()
        guard lstat(url.path, &pathStatus) == 0,
              pathStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              pathStatus.st_uid == getuid(),
              pathStatus.st_nlink == 1,
              pathStatus.st_mode & 0o777 == 0o600,
              pathStatus.st_size >= 0,
              pathStatus.st_size <= maximumSize
        else { return nil }

        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == pathStatus.st_dev,
              openedStatus.st_ino == pathStatus.st_ino,
              openedStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              openedStatus.st_uid == getuid(),
              openedStatus.st_nlink == 1,
              openedStatus.st_mode & 0o777 == 0o600,
              openedStatus.st_size <= maximumSize
        else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readDataToEndOfFile()
    }

    static func write(_ data: Data, to url: URL) throws {
        guard data.count <= maximumSize else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])

        var directoryStatus = stat()
        guard lstat(directory.path, &directoryStatus) == 0,
              directoryStatus.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryStatus.st_uid == getuid()
        else { throw CocoaError(.fileWriteNoPermission) }
        guard chmod(directory.path, 0o700) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }

        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(directoryFD) }

        let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary { unlinkat(directoryFD, temporaryName, 0) }
        }

        guard fchmod(descriptor, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw CocoaError(.fileWriteUnknown) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              renameat(directoryFD, temporaryName, directoryFD, url.lastPathComponent) == 0,
              fsync(directoryFD) == 0
        else { throw CocoaError(.fileWriteUnknown) }
        shouldRemoveTemporary = false
    }
}
