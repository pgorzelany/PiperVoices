# Piper speech runtime

The two speech Audio Unit extensions build this source package. `piper1-gpl-spm` 0.1.25 (`acd9fa26f318824db20f69fc595166f28eaca163`) pins the underlying Piper source to `304d5dac29c57a30d43fad09ef4b3a70a795b1bc`. The vendored files and original SHA-256 hashes are listed in [source-manifest.json](source-manifest.json). License texts for both projects are in [Licenses](Licenses). Piper's JSON header is nlohmann/json 3.11.2 (MIT). The uni-algo header includes its public-domain and MIT license texts.

The [package manifest](../Package.swift) pins eSpeak NG SwiftPM 2026.09.11 and the SHA-256 of Microsoft's ONNX Runtime 1.22.0 static XCFramework. eSpeak NG's pinned source checkout includes espeak-ng `699e79690f23e2558d990a3a78b0050745b96932` and libsonic `9a8d05dc0baa9159fc322dd9905a04e23b161337`. The bundled eSpeak dictionaries and runtime licenses ship within the extension's Voice resources.

Local Piper changes:

- Cap decoder windows at 64 latent frames while preserving the 32-frame first window, 12-frame context, and timing-based pacing.
- Require split encoder/decoder graphs. The Open JTalk frontend is omitted because the registered voices use eSpeak.
- Guard eSpeak initialization, phonemization, and termination across concurrent instances. Release the shared eSpeak state when the last model closes.
- Own initialization with RAII, translate C++ exceptions at the Swift-facing C boundary, and release per-request native buffers after synthesis or cancellation.

The checked-in native sources are built directly. Package resolution does not patch a checkout or copy binaries from VoiceLab.
