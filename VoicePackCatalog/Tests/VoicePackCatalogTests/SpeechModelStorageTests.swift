import Foundation
import Testing
@testable import VoicePackCatalog

private func fixturePack(revision: String = "v1") -> SpeechModelPack {
    SpeechModelPack(id: "fixture", revision: revision, downloadBytes: 3, files: [
        SpeechModelFile(path: "weights/model.bin", url: URL(string: "https://example.com/model.bin")!,
                        sha256: String(repeating: "a", count: 64), byteCount: 3)
    ])
}

@Test func shippedCatalogIncludesEverySupportedLanguage() {
    #expect(Set(SpeechVoiceCatalog.voices.map(\.language)) == ["en-US", "fr-FR", "it-IT", "es-ES", "pl-PL"])
    #expect(SpeechVoiceCatalog.bundledEnglish.name == "Mike")
    #expect(SpeechVoiceCatalog.voice(id: "com.enclaveai.voice.fr")?.name == "Gilles")
    #expect(SpeechVoiceCatalog.voice(id: "com.enclaveai.voice.pl")?.name == "MC_Speech")
    #expect(Set(SpeechVoiceCatalog.voices.compactMap(\.modelPackID)) == ["piper-fr-v1", "piper-it-v1", "piper-es-v1", "piper-pl-v1"])
    #expect(Set(SpeechVoiceCatalog.packs.map(\.id)) == Set(SpeechVoiceCatalog.voices.compactMap(\.modelPackID)))
    for pack in SpeechVoiceCatalog.packs {
        #expect(pack.files.count == 4)
        #expect(pack.files.allSatisfy { $0.byteCount > 0 })
        #expect(pack.downloadBytes == pack.files.reduce(0) { $0 + $1.byteCount })
        #expect(pack.files.contains { $0.path.hasSuffix(".encoder.onnx") })
        #expect(pack.files.contains { $0.path.hasSuffix(".decoder.onnx") })
        #expect(pack.files.contains { $0.path.hasSuffix(".onnx.json") })
        #expect(pack.files.contains { $0.path == "MODEL_CARD" })
    }
}

@Test func modelInstallationRequiresMatchingManifestAndCompleteFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("weights"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pack = fixturePack()
    let file = try SpeechModelStorage.fileURL(for: pack.files[0], in: directory)
    try Data([1, 2, 3]).write(to: file)
    #expect(!SpeechModelStorage.installationMatches(pack, in: directory))
    try JSONEncoder().encode(SpeechModelInstallation(pack: pack)).write(to: SpeechModelStorage.installationURL(in: directory))
    #expect(SpeechModelStorage.installationMatches(pack, in: directory))
    #expect(!SpeechModelStorage.installationMatches(fixturePack(revision: "v2"), in: directory))
    try Data([1, 2]).write(to: file)
    #expect(!SpeechModelStorage.installationMatches(pack, in: directory))
}

@Test func modelPathsRejectTraversalAndSymlinkEscapes() throws {
    for path in ["../model", "/model", "a/../../model", "a//model", "a/./model", "a\\model", ""] {
        #expect(!SpeechModelStorage.isSafeRelativePath(path))
    }
    #expect(SpeechModelStorage.isSafeRelativePath("model.mlmodelc/weights/weight.bin"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("weights"), withDestinationURL: directory.deletingLastPathComponent())
    #expect(throws: (any Error).self) {
        try SpeechModelStorage.fileURL(for: fixturePack().files[0], in: directory)
    }
}

@Test func modelFingerprintChangesWithManifestAndUnknownPacksAreNotResolved() {
    #expect(fixturePack().fingerprint.count == 64)
    #expect(fixturePack().fingerprint == fixturePack().fingerprint)
    #expect(fixturePack().fingerprint != fixturePack(revision: "v2").fingerprint)
    #expect(throws: (any Error).self) { try SpeechModelStorage.directory(for: fixturePack()) }
    #expect(SpeechVoiceCatalog.voice(id: BundledSpeechVoice.identifier) == SpeechVoiceCatalog.bundledEnglish)
    #expect(SpeechVoiceCatalog.voice(id: "unknown") == nil)
}

@Test func modelStorageRequiresAnAppGroup() throws {
    #expect(throws: VoiceDownloadError.unavailable) { try SpeechModelStorage.rootDirectory(group: nil) }
    let group = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let root = try SpeechModelStorage.rootDirectory(group: group)
    #expect(root == group.appendingPathComponent("SpeechModels", isDirectory: true))
    #expect(!FileManager.default.fileExists(atPath: group.path))
}

@Test func voiceStorageReadsTheSelectedBundleConfiguration() throws {
    let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixtures) }

    let host = try makeBundle(in: fixtures, appGroup: "group.example.host.voices")
    let provider = try makeBundle(in: fixtures, appGroup: "ABCDEFGHIJ.example.provider.voices")
    #expect(SpeechModelStorage.appGroupIdentifier(in: host) == "group.example.host.voices")
    #expect(SpeechModelStorage.appGroupIdentifier(in: provider) == "ABCDEFGHIJ.example.provider.voices")

    let pack = try #require(SpeechVoiceCatalog.packs.first)
    let disabledConfigurations: [Any?] = [
        nil, "", " ", "$(SPEECH_VOICE_APP_GROUP)", "${SPEECH_VOICE_APP_GROUP}", 42, "../UnrelatedGroup"
    ]
    for configuration in disabledConfigurations {
        let bundle = try makeBundle(in: fixtures, appGroup: configuration)
        #expect(SpeechModelStorage.appGroupIdentifier(in: bundle) == nil)
        #expect(throws: VoiceDownloadError.unavailable) { try SpeechModelStorage.directory(for: pack, bundle: bundle) }
        #expect(!SpeechModelStorage.isInstalled(pack, bundle: bundle))
    }
    #expect(SpeechVoiceCatalog.bundledEnglish.modelPackID == nil)
}

private func makeBundle(in directory: URL, appGroup: Any?) throws -> Bundle {
    let id = UUID().uuidString
    let bundle = directory.appendingPathComponent("\(id).bundle", isDirectory: true)
    #if os(macOS)
    let plistDirectory = bundle.appendingPathComponent("Contents", isDirectory: true)
    #else
    let plistDirectory = bundle
    #endif
    try FileManager.default.createDirectory(at: plistDirectory, withIntermediateDirectories: true)
    var info: [String: Any] = [
        "CFBundleIdentifier": "org.example.voice-pack-tests.\(id)",
        "CFBundlePackageType": "BNDL"
    ]
    info["SpeechVoiceAppGroup"] = appGroup
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: plistDirectory.appendingPathComponent("Info.plist"))
    return try #require(Bundle(url: bundle))
}

@Test func readyModelCannotUseLinkedPackDirectoryOrMarker() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let pack = fixturePack()
    let ready = directory.appendingPathComponent("ready")
    try FileManager.default.createDirectory(at: ready.appendingPathComponent("weights"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data([1, 2, 3]).write(to: SpeechModelStorage.fileURL(for: pack.files[0], in: ready))
    let marker = SpeechModelStorage.installationURL(in: ready)
    try JSONEncoder().encode(SpeechModelInstallation(pack: pack)).write(to: marker)
    #expect(SpeechModelStorage.installationMatches(pack, in: ready))

    let alias = directory.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: ready)
    #expect(!SpeechModelStorage.installationMatches(pack, in: alias))

    let markerCopy = ready.appendingPathComponent("marker-copy")
    try FileManager.default.moveItem(at: marker, to: markerCopy)
    try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: markerCopy)
    #expect(!SpeechModelStorage.installationMatches(pack, in: ready))
}
