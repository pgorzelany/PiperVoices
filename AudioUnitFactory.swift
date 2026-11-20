import AVFAudio

@objc(AudioUnitFactory)
final class AudioUnitFactory: NSObject, AUAudioUnitFactory {
    private var instance: AUAudioUnit?

    func beginRequest(with context: NSExtensionContext) {}

    func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try BundledSpeechAudioUnit(componentDescription: componentDescription, options: [])
        instance = unit
        return unit
    }
}
