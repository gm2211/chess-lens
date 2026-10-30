// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoardVision",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BoardVision", targets: ["BoardVision"])],
    targets: [
        .target(name: "BoardVision", resources: [.process("Resources")]),
        .testTarget(name: "BoardVisionTests", dependencies: ["BoardVision"], resources: [.copy("Fixtures")]),
    ]
)
