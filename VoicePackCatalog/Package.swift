// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoicePackCatalog",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "VoicePackCatalog", targets: ["VoicePackCatalog"])],
    targets: [
        .target(name: "VoicePackCatalog", resources: [.process("Resources")]),
        .testTarget(name: "VoicePackCatalogTests", dependencies: ["VoicePackCatalog"])
    ]
)
