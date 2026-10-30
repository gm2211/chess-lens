// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ChessCore", targets: ["ChessCore"])],
    targets: [
        .target(name: "ChessCore"),
        .testTarget(name: "ChessCoreTests", dependencies: ["ChessCore"]),
    ]
)
