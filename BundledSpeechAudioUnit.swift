@preconcurrency import AVFAudio
import EnclavePiperSpeech
import Foundation
import os
import VoicePackCatalog

// Audio Unit control and render entry points can run concurrently. Only the synthesis
// worker uses the engine, and the bounded PCM queue owns all state shared with rendering.
final class BundledSpeechAudioUnit: AVSpeechSynthesisProviderAudioUnit, @unchecked Sendable {
    private static let log = Logger(subsystem: "com.enclaveai.speech", category: "synthesis")
    // The Audio Unit can run inside an Apple host process.
    private static let providerBundle = Bundle(for: AudioUnitFactory.self)

    private let outputBus: AUAudioUnitBus
    private var buses: AUAudioUnitBusArray!
    private var inputs: AUAudioUnitBusArray!
    private let audio = SpeechPCMQueue()
    private let scratch = SpeechRenderStorage(capacity: 16_384)
    private let worker = OSAllocatedUnfairLock(initialState: Optional<Task<Void, Never>>.none)
    private let bundledDirectory: URL
    private let synthesizer: PiperSpeechEngine

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: BundledSpeechVoice.sampleRate, channels: 1)!
        outputBus = try AUAudioUnitBus(format: format)
        guard let directory = Self.providerBundle.resourceURL?.appendingPathComponent("Voice"),
              FileManager.default.fileExists(atPath: directory.path) else {
            throw SpeechProviderError.missingResources
        }
        bundledDirectory = directory
        synthesizer = PiperSpeechEngine(
            espeakDataDirectory: directory.appendingPathComponent("espeak-ng-data", isDirectory: true),
            outputSampleRate: Int(BundledSpeechVoice.sampleRate)
        )
        try super.init(componentDescription: componentDescription, options: options)
        maximumFramesToRender = 4_096
        outputBus.supportedChannelCounts = [1]
        buses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [])
    }

    deinit {
        worker.withLock { $0?.cancel() }
        audio.cancel()
    }

    override var outputBusses: AUAudioUnitBusArray { buses }
    override var inputBusses: AUAudioUnitBusArray { inputs }

    override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        format.commonFormat == .pcmFormatFloat32 && format.channelCount == 1 &&
            format.sampleRate == BundledSpeechVoice.sampleRate &&
            super.shouldChange(to: format, for: bus)
    }

    override var speechVoices: [AVSpeechSynthesisProviderVoice] {
        get {
            SpeechVoiceCatalog.voices.filter(Self.isAvailable).map { voice in
                AVSpeechSynthesisProviderVoice(name: voice.name, identifier: voice.id,
                                               primaryLanguages: [voice.language], supportedLanguages: [voice.language])
            }
        }
        set {}
    }

    override func deallocateRenderResources() {
        worker.withLock { task in
            let previous = task
            previous?.cancel()
            audio.cancel()
            let synthesizer = synthesizer
            task = Task { @Sendable in
                await previous?.value
                do {
                    try await synthesizer.release()
                } catch {
                    Self.log.error("Speech model could not be released")
                }
            }
        }
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { [weak self] flags, _, count, bus, output, _, _ in
            guard let self else { return kAudioComponentErr_InstanceInvalidated }
            guard bus == 0 else { return kAudioUnitErr_InvalidElement }
            guard Int(count) <= self.scratch.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count == 1 else { return kAudio_ParamError }
            let requestedBytes = count * UInt32(MemoryLayout<Float>.stride)
            let destination: UnsafeMutablePointer<Float>
            if let data = buffers[0].mData {
                guard buffers[0].mDataByteSize >= requestedBytes else { return kAudio_ParamError }
                destination = data.assumingMemoryBound(to: Float.self)
            } else {
                destination = self.scratch.samples
                buffers[0].mData = UnsafeMutableRawPointer(destination)
            }

            let offline = self.isRenderingOffline || flags.pointee.contains(.offlineUnitRenderAction_Render)
            flags.pointee.remove([.unitRenderAction_OutputIsSilence, .offlineUnitRenderAction_Complete])
            let result = self.audio.render(into: destination, count: Int(count), offline: offline)
            guard result.status == noErr else { return result.status }
            destination.advanced(by: result.count).update(repeating: 0, count: Int(count) - result.count)
            buffers[0].mNumberChannels = 1
            // Some AU hosts reject a zero-byte buffer even when the action flags mark it silent.
            buffers[0].mDataByteSize = offline && result.count > 0
                ? UInt32(result.count * MemoryLayout<Float>.stride)
                : requestedBytes
            if result.count == 0 { flags.pointee.insert(.unitRenderAction_OutputIsSilence) }
            if result.complete { flags.pointee.insert(.offlineUnitRenderAction_Complete) }
            return noErr
        }
    }

    override func synthesizeSpeechRequest(_ speechRequest: AVSpeechSynthesisProviderRequest) {
        worker.withLock { task in
            let previous = task
            previous?.cancel()
            let request = audio.begin()
            let audio = audio
            let synthesizer = synthesizer
            let bundledDirectory = bundledDirectory
            task = Task(priority: .userInitiated) { @Sendable in
                // Piper can suspend while it emits PCM. Let the previous request unwind
                // its native decoder before preparing or generating a replacement.
                await previous?.value
                do {
                    try Task.checkCancellation()
                    guard let voice = SpeechVoiceCatalog.voice(id: speechRequest.voice.identifier) else {
                        throw SpeechProviderError.unavailable
                    }
                    let text = try SpeechMarkupText().text(from: speechRequest.ssmlRepresentation)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        audio.finish(request: request)
                        return
                    }
                    let directory = try Self.modelDirectory(for: voice, bundledDirectory: bundledDirectory)
                    try await synthesizer.prepare(modelDirectory: directory)
                    try await synthesizer.generate(text: text) { chunk in
                        #if DEBUG
                        if let completedAt = chunk.decoderCompletedUptime {
                            audio.recordDecoderWindow(request: request, completedAt: completedAt)
                        }
                        #endif
                        var offset = 0
                        while offset < chunk.samples.count {
                            try Task.checkCancellation()
                            let accepted = audio.append(chunk.samples, offset: offset, request: request)
                            guard let accepted else { throw CancellationError() }
                            offset += accepted
                            if accepted == 0 { try await Task.sleep(for: .milliseconds(2)) }
                        }
                    }
                    audio.finish(request: request)
                } catch is CancellationError {
                    audio.finish(request: request)
                } catch {
                    Self.log.error("Speech synthesis failed")
                    audio.finish(request: request, failed: true)
                }
            }
        }
    }

    override func cancelSpeechRequest() {
        worker.withLock {
            $0?.cancel()
            audio.cancel()
        }
    }

    private static func modelDirectory(for voice: SpeechVoiceDescriptor, bundledDirectory: URL) throws -> URL {
        if voice == SpeechVoiceCatalog.bundledEnglish { return bundledDirectory }
        guard let id = voice.modelPackID, let pack = SpeechVoiceCatalog.pack(id: id) else {
            throw SpeechProviderError.unavailable
        }
        guard let directory = try? SpeechModelStorage.directory(for: pack, bundle: providerBundle),
              SpeechModelStorage.installationMatches(pack, in: directory) else {
            throw SpeechProviderError.unavailable
        }
        return directory
    }

    private static func isAvailable(_ voice: SpeechVoiceDescriptor) -> Bool {
        guard let id = voice.modelPackID else { return voice == SpeechVoiceCatalog.bundledEnglish }
        guard let pack = SpeechVoiceCatalog.pack(id: id) else { return false }
        return SpeechModelStorage.isInstalled(pack, bundle: providerBundle)
    }
}

private enum SpeechProviderError: Error {
    case missingResources, invalidMarkup, unavailable
}

private final class SpeechRenderStorage: @unchecked Sendable {
    let capacity: Int
    let samples: UnsafeMutablePointer<Float>

    init(capacity: Int) {
        self.capacity = capacity
        samples = .allocate(capacity: capacity)
        samples.initialize(repeating: 0, count: capacity)
    }

    deinit { samples.deallocate() }
}

private final class SpeechPCMQueue: @unchecked Sendable {
    private enum Phase {
        case idle
        case producing
        case finished
    }

    private struct State {
        var request: UInt64 = 0
        var readIndex = 0
        var count = 0
        var phase: Phase = .idle
        var failed = false
        #if DEBUG
        var firstRenderedSpeechUptime: TimeInterval?
        var reportedLaterDecoderWindow = false
        #endif
    }

    struct RenderResult {
        var status: OSStatus = noErr
        var count = 0
        var complete = false
        fileprivate var wait: Wait?
    }

    fileprivate enum Wait {
        case request
        case frames(UInt64)
    }

    private static let log = Logger(subsystem: "com.enclaveai.speech", category: "synthesis")
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let storage = SpeechRenderStorage(capacity: 48_000)

    func begin() -> UInt64 {
        lock.withLock { state in
            state = State(request: state.request &+ 1, phase: .producing)
            return state.request
        }
    }

    func cancel() {
        lock.withLock { $0 = State(request: $0.request &+ 1) }
    }

    func finish(request: UInt64, failed: Bool = false) {
        lock.withLock { state in
            guard state.request == request else { return }
            state.phase = .finished
            state.failed = failed
            #if DEBUG
            if !failed { Self.log.debug("Speech generation finished request=\(request, privacy: .public)") }
            #endif
        }
    }

    func append(_ input: [Float], offset: Int, request: UInt64) -> Int? {
        lock.withLock { state in
            guard state.request == request, state.phase == .producing else { return nil }
            let count = min(input.count - offset, storage.capacity - state.count)
            guard count > 0 else { return 0 }
            input.withUnsafeBufferPointer { source in
                let writeIndex = (state.readIndex + state.count) % storage.capacity
                let first = min(count, storage.capacity - writeIndex)
                storage.samples.advanced(by: writeIndex).update(from: source.baseAddress!.advanced(by: offset), count: first)
                if first < count {
                    storage.samples.update(from: source.baseAddress!.advanced(by: offset + first), count: count - first)
                }
            }
            state.count += count
            return count
        }
    }

    #if DEBUG
    func recordDecoderWindow(request: UInt64, completedAt: TimeInterval) {
        lock.withLock { state in
            guard state.request == request, !state.reportedLaterDecoderWindow,
                  let firstRendered = state.firstRenderedSpeechUptime, completedAt > firstRendered else { return }
            state.reportedLaterDecoderWindow = true
            Self.log.debug("Speech decoded a later window after rendering PCM request=\(request, privacy: .public)")
        }
    }
    #endif

    func render(into output: UnsafeMutablePointer<Float>, count requested: Int, offline: Bool) -> RenderResult {
        var waitingFor: UInt64?
        let read: (inout State) -> RenderResult = { [storage] state in
            if let waitingFor, waitingFor != state.request { return RenderResult(complete: true) }
            if state.phase == .idle { return RenderResult(wait: offline ? .request : nil) }
            if state.failed {
                state.phase = .idle
                return RenderResult(status: kAudioUnitErr_FailedInitialization)
            }
            if offline && state.phase == .producing && state.count < requested {
                return RenderResult(wait: .frames(state.request))
            }
            let count = min(requested, state.count)
            let first = min(count, storage.capacity - state.readIndex)
            output.update(from: storage.samples.advanced(by: state.readIndex), count: first)
            if first < count {
                output.advanced(by: first).update(from: storage.samples, count: count - first)
            }
            state.readIndex = (state.readIndex + count) % storage.capacity
            state.count -= count
            #if DEBUG
            if offline && state.phase == .producing && state.firstRenderedSpeechUptime == nil &&
                UnsafeBufferPointer(start: output, count: count).contains(where: { abs($0) > 0.0001 }) {
                state.firstRenderedSpeechUptime = ProcessInfo.processInfo.systemUptime
                let request = state.request
                Self.log.debug("Speech rendered PCM during generation request=\(request, privacy: .public)")
            }
            #endif
            let complete = state.phase == .finished && state.count == 0
            if complete { state.phase = .idle }
            return RenderResult(count: count, complete: complete)
        }
        guard offline else { return lock.withLockIfAvailableUnchecked(read) ?? RenderResult() }
        let started = ContinuousClock.now
        while true {
            let result = lock.withLockUnchecked(read)
            switch result.wait {
            case nil:
                return result
            case .request:
                // The remote AU can receive its first pull before the system delivers the
                // synthesis request. An idle pull is never the end of a previous utterance.
                guard ContinuousClock.now < started + .milliseconds(50) else { return RenderResult() }
            case .frames(let request):
                guard ContinuousClock.now < started + .seconds(30) else {
                    return RenderResult(status: kAudioUnitErr_CannotDoInCurrentContext)
                }
                waitingFor = request
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}

private final class SpeechMarkupText: NSObject, XMLParserDelegate {
    private var result = ""

    func text(from markup: String) throws -> String {
        let parser = XMLParser(data: Data(markup.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw SpeechProviderError.invalidMarkup }
        return result
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { result += string }
}
