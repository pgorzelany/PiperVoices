import Foundation

public struct SpeechModelInstallation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let packID: String
    public let manifestFingerprint: String

    public init(pack: SpeechModelPack) {
        schemaVersion = 1
        packID = pack.id
        manifestFingerprint = pack.fingerprint
    }
}

public enum SpeechModelStorage {
    public static let installedMarkerName = "installed.json"

    public static let appGroupIdentifier = appGroupIdentifier(in: .main)

    static func appGroupIdentifier(in bundle: Bundle) -> String? {
        guard let identifier = bundle.infoDictionary?["SpeechVoiceAppGroup"] as? String,
              !identifier.hasPrefix("."), isSafeComponent(identifier) else { return nil }
        return identifier
    }

    public static func rootDirectory() throws -> URL {
        try rootDirectory(in: .main)
    }

    static func rootDirectory(in bundle: Bundle) throws -> URL {
        guard let identifier = appGroupIdentifier(in: bundle) else { throw VoiceDownloadError.unavailable }
        return try rootDirectory(group: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier))
    }

    static func rootDirectory(group: URL?) throws -> URL {
        guard let group else { throw VoiceDownloadError.unavailable }
        let root = group.appendingPathComponent("SpeechModels", isDirectory: true)
        try rejectSymbolicLink(root)
        return root
    }

    public static func directory(for pack: SpeechModelPack, bundle: Bundle = .main) throws -> URL {
        guard SpeechVoiceCatalog.pack(id: pack.id) == pack else {
            throw VoiceDownloadError.invalidManifest
        }
        return try rootDirectory(in: bundle).appendingPathComponent(pack.id, isDirectory: true)
    }

    public static func installationURL(in directory: URL) -> URL {
        directory.appendingPathComponent(installedMarkerName)
    }

    public static func isInstalled(_ pack: SpeechModelPack, bundle: Bundle = .main) -> Bool {
        guard let directory = try? directory(for: pack, bundle: bundle) else { return false }
        return installationMatches(pack, in: directory)
    }

    /// File hashes are checked by the installer before it atomically publishes this marker.
    public static func installationMatches(_ pack: SpeechModelPack, in directory: URL) -> Bool {
        let markerURL = installationURL(in: directory)
        guard (try? rejectSymbolicLink(directory)) != nil,
              let markerType = try? markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              markerType.isRegularFile == true, markerType.isSymbolicLink != true,
              let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(SpeechModelInstallation.self, from: data),
              marker == SpeechModelInstallation(pack: pack) else { return false }
        return pack.files.allSatisfy { file in
            guard isSafeRelativePath(file.path),
                  let url = try? fileURL(for: file, in: directory),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, Int64(values.fileSize ?? -1) == file.byteCount else { return false }
            return true
        }
    }

    public static func fileURL(for file: SpeechModelFile, in directory: URL) throws -> URL {
        guard isSafeRelativePath(file.path) else { throw VoiceDownloadError.invalidManifest }
        try rejectSymbolicLink(directory)
        var url = directory
        for component in file.path.split(separator: "/") {
            url.appendPathComponent(String(component))
            try rejectSymbolicLink(url)
        }
        return url
    }

    public static func rejectSymbolicLink(_ url: URL) throws {
        // Ancestors may contain system aliases such as /var.
        if let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType,
           type == .typeSymbolicLink { throw VoiceDownloadError.invalidFile }
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { isSafeComponent(String($0)) }
    }

    static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".." &&
        component.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.").contains($0) }
    }
}
