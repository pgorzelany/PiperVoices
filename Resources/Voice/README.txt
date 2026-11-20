PiperVoices builds without proprietary app assets. To synthesize speech, place these files in the extension's Voice resource directory.

- espeak-ng-data/ from the eSpeak NG version pinned in EnclavePiperSpeech/Package.swift. The exact upstream source is listed in EnclavePiperSpeech/Vendor/NOTICE.md.
- One split Piper encoder (*.encoder.onnx), its corresponding decoder (*.decoder.onnx), and the model configuration (*.onnx.json). Use matching names and a compatible model entry in VoicePackCatalog.
- Model cards, attribution, and license notices appropriate to the supplied voices and dependencies.

The optional voice catalog and model installation code are in VoicePackCatalog. The repository does not include model weights.
