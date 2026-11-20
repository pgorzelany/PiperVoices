// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "EnclavePiperSpeech",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EnclavePiperSpeech", targets: ["EnclavePiperSpeech"])
    ],
    dependencies: [
        .package(url: "https://github.com/piper-tts-apps/espeak-ng-spm.git", exact: "2026.9.11")
    ],
    targets: [
        .target(name: "EnclavePiperSpeech", dependencies: ["CPiper"]),
        .testTarget(name: "EnclavePiperSpeechTests", dependencies: ["EnclavePiperSpeech"]),
        .target(
            name: "CPiper",
            dependencies: [
                .product(name: "libespeak-ng", package: "espeak-ng-spm"),
                "onnxruntime"
            ],
            path: "Vendor/Piper",
            cxxSettings: [.headerSearchPath("headers")]
        ),
        .binaryTarget(
            name: "onnxruntime",
            url: "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.22.0.zip",
            checksum: "90d9de5a139087a6b05a18125d01d01d198820e1731e6f0f11b38749b2ab181f"
        )
    ],
    cxxLanguageStandard: .cxx17
)
