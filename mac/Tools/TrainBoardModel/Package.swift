// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TrainBoardModel",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TrainBoardModel", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
