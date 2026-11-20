import CryptoKit
import Foundation

public struct SpeechVoiceDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let modelPackID: String?
    public let style: String?

    public init(id: String, name: String, language: String, modelPackID: String? = nil, style: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.modelPackID = modelPackID
        self.style = style
    }
}

public struct SpeechModelFile: Codable, Hashable, Sendable {
    public let path: String
    public let url: URL
    public let sha256: String
    public let byteCount: Int64

    public init(path: String, url: URL, sha256: String, byteCount: Int64) {
        self.path = path
        self.url = url
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public struct SpeechModelPack: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let revision: String
    public let downloadBytes: Int64
    public let files: [SpeechModelFile]

    public init(id: String, revision: String, downloadBytes: Int64, files: [SpeechModelFile]) {
        self.id = id
        self.revision = revision
        self.downloadBytes = downloadBytes
        self.files = files
    }

    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // All encoded properties are concrete Codable values; encoding cannot fail.
        let data = try! encoder.encode(self)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SpeechVoiceCatalog {
    public static let bundledEnglish = SpeechVoiceDescriptor(
        id: BundledSpeechVoice.identifier, name: BundledSpeechVoice.name, language: BundledSpeechVoice.language
    )

    public static var voices: [SpeechVoiceDescriptor] { [bundledEnglish] + contents.voices }
    public static var packs: [SpeechModelPack] { contents.packs }
    public static func voice(id: String) -> SpeechVoiceDescriptor? { voices.first { $0.id == id } }
    public static func pack(id: String) -> SpeechModelPack? { packs.first { $0.id == id } }

    private struct Contents: Decodable, Sendable {
        var voices: [SpeechVoiceDescriptor]
        var packs: [SpeechModelPack]
    }

    private static let contents: Contents = {
        guard let url = Bundle.module.url(forResource: "VoiceCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let contents = try? JSONDecoder().decode(Contents.self, from: data),
              Set(contents.packs.map(\.id)).count == contents.packs.count,
              Set(contents.voices.map(\.id) + [bundledEnglish.id]).count == contents.voices.count + 1,
              contents.packs.allSatisfy(isValid),
              contents.voices.allSatisfy({ voice in
                  !voice.id.isEmpty && !voice.name.isEmpty && !voice.language.isEmpty &&
                  contents.packs.contains { $0.id == voice.modelPackID }
              }) else { return Contents(voices: [], packs: []) }
        return contents
    }()

    public static func isValid(_ pack: SpeechModelPack) -> Bool {
        guard SpeechModelStorage.isSafeComponent(pack.id), !pack.id.hasPrefix("."), !pack.revision.isEmpty,
              !pack.files.isEmpty, pack.downloadBytes > 0,
              Set(pack.files.map(\.path)).count == pack.files.count else { return false }
        var total: Int64 = 0
        for file in pack.files {
            let marker = SpeechModelStorage.installedMarkerName
            guard SpeechModelStorage.isSafeRelativePath(file.path), file.path != marker, !file.path.hasPrefix(marker + "/"),
                  file.url.scheme == "https", file.url.host != nil,
                  file.byteCount >= 0, file.sha256.count == 64,
                  file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return false }
            if file.byteCount == 0 && file.sha256 != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" { return false }
            let (sum, overflow) = total.addingReportingOverflow(file.byteCount)
            guard !overflow else { return false }
            total = sum
        }
        return total == pack.downloadBytes
    }
}
