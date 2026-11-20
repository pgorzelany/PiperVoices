import CryptoKit
import Darwin
import Foundation

public enum SpeechModelFiles {
    public static func makeStagingDirectory(in root: URL) throws -> URL {
        try SpeechModelStorage.rejectSymbolicLink(root)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var protectedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(values)
        try removeAbandonedStaging(in: root)
        let staging = stagingURL(in: root)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        return staging
    }

    public static func verify(_ url: URL, expected: SpeechModelFile, checkCancellation: () throws -> Void) throws {
        try SpeechModelStorage.rejectSymbolicLink(url)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, Int64(values.fileSize ?? -1) == expected.byteCount else {
            throw VoiceDownloadError.invalidFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try checkCancellation()
            hash.update(data: data)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected.sha256 else { throw VoiceDownloadError.invalidFile }
    }

    public static func writeInstallationMarker(for pack: SpeechModelPack, in staging: URL) throws {
        let marker = try JSONEncoder().encode(SpeechModelInstallation(pack: pack))
        try marker.write(to: SpeechModelStorage.installationURL(in: staging), options: .atomic)
        guard SpeechModelStorage.installationMatches(pack, in: staging) else { throw VoiceDownloadError.invalidFile }
    }

    /// Publishes a verified pack in one rename. Callers remove the staging path after returning.
    @discardableResult
    public static func publish(_ pack: SpeechModelPack, from staging: URL, in root: URL) throws -> Bool {
        try withMutationLock(in: root) {
            let destination = root.appendingPathComponent(pack.id, isDirectory: true)
            try SpeechModelStorage.rejectSymbolicLink(destination)
            guard !SpeechModelStorage.installationMatches(pack, in: destination) else { return false }
            if FileManager.default.fileExists(atPath: destination.path) {
                // Swapping leaves the old directory at the unadvertised staging path.
                guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            return true
        }
    }

    public static func remove(_ pack: SpeechModelPack, in root: URL) throws {
        try SpeechModelStorage.rejectSymbolicLink(root)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let unpublished = stagingURL(in: root)
        try withMutationLock(in: root) {
            let destination = root.appendingPathComponent(pack.id, isDirectory: true)
            try SpeechModelStorage.rejectSymbolicLink(destination)
            if manager.fileExists(atPath: destination.path) {
                try manager.moveItem(at: destination, to: unpublished)
            }
        }
        // Availability changed at the rename. Orphaned staging is cleaned up on a future install.
        try? manager.removeItem(at: unpublished)
    }

    private static func withMutationLock<Result>(in root: URL, _ operation: () throws -> Result) throws -> Result {
        let lock = root.appendingPathComponent(".mutations.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        return try operation()
    }

    private static func stagingURL(in root: URL) -> URL {
        root.appendingPathComponent(".staging-\(getpid())-\(UUID().uuidString)", isDirectory: true)
    }

    private static func removeAbandonedStaging(in root: URL) throws {
        let manager = FileManager.default
        for directory in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let pieces = directory.lastPathComponent.split(separator: "-", maxSplits: 2)
            guard pieces.count == 3, pieces[0] == ".staging", let pid = pid_t(pieces[1]), pid > 0,
                  UUID(uuidString: String(pieces[2])) != nil, kill(pid, 0) != 0, errno == ESRCH,
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            do {
                try manager.removeItem(at: directory)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {}
        }
    }
}
