# PiperVoices

PiperVoices is an iOS and macOS speech synthesis Audio Unit extension. It accepts Apple's speech requests and streams mono PCM from a local Piper model. The provider runs out of process.

## Build the extension

Clone this repository and open `PiperVoices.xcodeproj` in Xcode 27 or newer.

```sh
xcodebuild -project PiperVoices.xcodeproj -scheme EnclaveSpeech-iOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PiperVoices.xcodeproj -scheme EnclaveSpeech-macOS \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

These commands build the provider without voice assets. See [voice assets](Resources/Voice/README.txt) for the expected files.

## Embed in a containing app

1. Add this repository as a Git submodule. The containing app records the exact provider commit.
2. Add the supplied iOS or macOS extension target to your Xcode integration. You can reference the standalone project as a subproject, or create an app-extension target that builds `AudioUnitFactory.swift` and `BundledSpeechAudioUnit.swift`, uses the supplied `Info.plist` and privacy manifest, and links the products of the local `EnclavePiperSpeech` and `VoicePackCatalog` packages. Embed the signed `.appex` in your app.
3. Set the target's bundle identifier, signing team, and version to match your distribution setup. For a separately branded provider, also set the Audio Unit manufacturer and subtype in the extension plist and the corresponding description used by your host. Give your voices unique identifiers if your provider can coexist with another installation of this catalog.
4. Supply compatible model and eSpeak data files in a folder reference named `Voice`, using files you have permission to redistribute. The sample catalog describes compatible split models and the install layout.

Apps that only use registered voices can select them through Apple's speech synthesizer. A host installing extra voices needs an App Group shared with the provider. Set `SPEECH_VOICE_APP_GROUP` for both targets, use the supplied example entitlements, and use `VoicePackCatalog` if you want the same model verification and installation code. Call `AVSpeechSynthesisProviderVoice.updateSpeechVoices()` when the installed list changes.

## Licenses

The extension and Piper engine integration are distributed under [GPLv3](LICENSE). The [VoicePackCatalog package](VoicePackCatalog/LICENSE) is MIT. [Engine provenance and third-party notices](EnclavePiperSpeech/Vendor/NOTICE.md) identify corresponding upstream source and the terms for dependencies. Models and training data have their own terms.
