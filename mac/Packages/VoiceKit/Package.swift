// swift-tools-version: 6.0
import PackageDescription

// Voice choice and the on-demand Kokoro download, kept free of sherpa-onnx so it builds and tests on its own:
// picking the best installed system voice, and fetching / verifying / unpacking the Kokoro model into Application Support.
let package = Package(
    name: "VoiceKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "VoiceKit", targets: ["VoiceKit"])],
    targets: [
        .target(name: "VoiceKit"),
        // Headless install of the Kokoro model: voice-install <archive path or URL> <dest-root> [sha256]
        .executableTarget(name: "voice-install", dependencies: ["VoiceKit"]),
        .testTarget(name: "VoiceKitTests", dependencies: ["VoiceKit"]),
    ]
)
