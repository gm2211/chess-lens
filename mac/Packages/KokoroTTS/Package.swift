// swift-tools-version: 6.0
import PackageDescription

// Kokoro-82M text-to-speech through sherpa-onnx's C API, linked statically.
// The static libraries come from mac/scripts/fetch-kokoro.sh (mac/vendor/kokoro/lib, gitignored). The search path is
// supplied by the consumer: the app's LIBRARY_SEARCH_PATHS (project.yml) or `-Xlinker -L…` (scripts/check-kokoro.sh).
let sherpaLibs = [
    "sherpa-onnx-c-api", "sherpa-onnx-core", "onnxruntime", "espeak-ng", "piper_phonemize", "ucd",
    "kaldi-native-fbank-core", "kaldi-decoder-core", "kissfft-float", "sherpa-onnx-fst", "sherpa-onnx-fstfar",
    "sherpa-onnx-kaldifst-core", "ssentencepiece_core",
]

let package = Package(
    name: "KokoroTTS",
    platforms: [.macOS(.v14)],
    products: [.library(name: "KokoroTTS", targets: ["KokoroTTS"])],
    targets: [
        .target(name: "CSherpaOnnx",
                linkerSettings: sherpaLibs.map { .linkedLibrary($0) } + [.linkedLibrary("c++")]),
        .target(name: "KokoroTTS", dependencies: ["CSherpaOnnx"]),
        .executableTarget(name: "kokoro-check", dependencies: ["KokoroTTS"]),
        .testTarget(name: "KokoroTTSTests", dependencies: ["KokoroTTS"]),
    ]
)
