import CPiper
import Foundation

/// Owns one Piper voice and advances its decoder only as the consumer accepts PCM.
public actor PiperSpeechEngine {
    public struct Chunk: Sendable {
        public let samples: [Float]
        public let decoderCompletedUptime: TimeInterval?
    }

    private let espeakDataDirectory: URL
    private let outputSampleRate: Int
    private var model: NativeModel?
    private var generating = false

    public init(espeakDataDirectory: URL, outputSampleRate: Int) {
        precondition(outputSampleRate > 0)
        self.espeakDataDirectory = espeakDataDirectory
        self.outputSampleRate = outputSampleRate
    }

    public func prepare(modelDirectory: URL) throws {
        guard !generating else { throw PiperSpeechError.busy }
        try Task.checkCancellation()
        if model?.directory == modelDirectory { return }

        model = nil
        let config = try Self.config(in: modelDirectory)
        let modelPath = config.deletingPathExtension().path(percentEncoded: false)
        let configPath = config.path(percentEncoded: false)
        let espeakPath = espeakDataDirectory.path(percentEncoded: false)
        guard Self.isRegularFile(espeakDataDirectory.appendingPathComponent("phontab")) else {
            throw PiperSpeechError.missingResources
        }
        guard let handle = enclave_piper_create(modelPath, configPath, espeakPath) else {
            throw PiperSpeechError.preparation
        }
        let prepared = NativeModel(handle: handle, directory: modelDirectory)
        try Task.checkCancellation()
        model = prepared
    }

    public func release() throws {
        guard !generating else { throw PiperSpeechError.busy }
        model = nil
    }

    public func generate(
        text: String,
        emit: @Sendable (Chunk) async throws -> Void
    ) async throws {
        guard !generating else { throw PiperSpeechError.busy }
        guard let model else { throw PiperSpeechError.preparation }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try Task.checkCancellation()

        let handle = model.handle
        generating = true
        defer {
            enclave_piper_reset(handle)
            generating = false
        }
        guard enclave_piper_start(handle, text) == ENCLAVE_PIPER_OK else {
            throw PiperSpeechError.synthesis
        }

        var converter: PCMResampler?
        while true {
            try Task.checkCancellation()
            var window = EnclavePiperWindow()
            let status = enclave_piper_next(handle, &window)
            let completedAt = ProcessInfo.processInfo.systemUptime
            try Task.checkCancellation()
            guard status == ENCLAVE_PIPER_OK || status == ENCLAVE_PIPER_DONE else {
                throw PiperSpeechError.synthesis
            }
            if window.frame_count > 0 {
                let sampleRate = Int(window.sample_rate)
                guard let samples = window.samples, (8_000...192_000).contains(sampleRate) else {
                    throw PiperSpeechError.synthesis
                }
                if converter == nil {
                    converter = PCMResampler(inputSampleRate: sampleRate, outputSampleRate: outputSampleRate)
                }
                let input = UnsafeBufferPointer(start: samples, count: window.frame_count)
                guard converter?.inputSampleRate == sampleRate, let output = converter?.convert(input) else {
                    throw PiperSpeechError.synthesis
                }
                try await emit(Chunk(samples: output, decoderCompletedUptime: completedAt))
            }
            if status == ENCLAVE_PIPER_DONE { break }
        }
        guard let tail = converter?.finish() else { throw PiperSpeechError.synthesis }
        if !tail.isEmpty {
            try await emit(Chunk(samples: tail, decoderCompletedUptime: nil))
        }
    }

    private static func config(in directory: URL) throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        )
        let configs = files.filter { $0.lastPathComponent.hasSuffix(".onnx.json") }
        guard configs.count == 1, let config = configs.first, isRegularFile(config) else {
            throw PiperSpeechError.missingResources
        }
        let stem = config.deletingPathExtension().deletingPathExtension()
        guard isRegularFile(stem.appendingPathExtension("encoder.onnx")),
              isRegularFile(stem.appendingPathExtension("decoder.onnx")) else {
            throw PiperSpeechError.missingResources
        }
        return config
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}

// The engine actor serializes all access to the handle and exclusively owns this object.
private final class NativeModel: @unchecked Sendable {
    let handle: OpaquePointer
    let directory: URL

    init(handle: OpaquePointer, directory: URL) {
        self.handle = handle
        self.directory = directory
    }

    deinit { enclave_piper_free(handle) }
}

private enum PiperSpeechError: LocalizedError {
    case busy, missingResources, preparation, synthesis

    var errorDescription: String? {
        switch self {
        case .busy: "This voice is already generating audio."
        case .missingResources: "The voice model resources are incomplete."
        case .preparation: "The voice model could not be loaded."
        case .synthesis: "The voice model could not generate audio."
        }
    }
}
