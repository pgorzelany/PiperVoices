import AudioToolbox

public enum BundledSpeechVoice {
    public static let identifier = "com.enclaveai.voice.en"
    public static let name = "Mike"
    public static let language = "en-US"
    public static let sampleRate = 24_000.0

    public static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_SpeechSynthesizer,
            componentSubType: 0x656E636C,
            componentManufacturer: 0x456E636C,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}
