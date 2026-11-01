import Foundation
import CSherpaOnnx

/// One loaded Kokoro model (sherpa-onnx offline TTS) for one accent. Synthesis is serialized on a private queue
/// and never runs on the caller's thread.
public final class KokoroEngine: @unchecked Sendable {
    public enum LoadError: Error, CustomStringConvertible {
        case missingFile(String), createFailed
        public var description: String {
            switch self {
            case .missingFile(let f): "Kokoro model file missing: \(f)"
            case .createFailed: "sherpa-onnx could not load the Kokoro model"
            }
        }
    }

    /// The fp32 model if present, else the int8 one.
    public static let modelNames = ["model.onnx", "model.int8.onnx"]
    public static let modelFiles = ["voices.bin", "tokens.txt", "espeak-ng-data"]

    public let accent: KokoroVoice.Accent
    public let sampleRate: Int
    private let tts: OpaquePointer
    private let queue = DispatchQueue(label: "app.chesslens.kokoro", qos: .userInitiated)

    /// Loads the model in `directory` (blocking, about a second). `threads` is onnxruntime's intra-op thread count.
    public init(directory: URL, accent: KokoroVoice.Accent, threads: Int = 4) throws {
        let fm = FileManager.default
        for f in Self.modelFiles + [accent.lexicon] where !fm.fileExists(atPath: directory.appendingPathComponent(f).path) {
            throw LoadError.missingFile(f)
        }
        func path(_ f: String) -> String { directory.appendingPathComponent(f).path }
        guard let modelName = Self.modelNames.first(where: { fm.fileExists(atPath: path($0)) }) else {
            throw LoadError.missingFile(Self.modelNames.joined(separator: " or "))
        }
        let model = path(modelName), voices = path("voices.bin"), tokens = path("tokens.txt")
        let data = path("espeak-ng-data"), lexicon = path(accent.lexicon), lang = accent.rawValue
        let created: OpaquePointer? = model.withCString { cModel in voices.withCString { cVoices in
            tokens.withCString { cTokens in data.withCString { cData in lexicon.withCString { cLex in
                lang.withCString { cLang in "cpu".withCString { cProvider in
                    var c = SherpaOnnxOfflineTtsConfig()
                    c.model.kokoro.model = cModel
                    c.model.kokoro.voices = cVoices
                    c.model.kokoro.tokens = cTokens
                    c.model.kokoro.data_dir = cData
                    c.model.kokoro.lexicon = cLex
                    c.model.kokoro.lang = cLang
                    c.model.kokoro.length_scale = 1.0
                    c.model.num_threads = Int32(threads)
                    c.model.debug = getenv("KOKORO_DEBUG") != nil ? 1 : 0
                    c.model.provider = cProvider
                    c.max_num_sentences = 1
                    c.silence_scale = 0.2
                    return SherpaOnnxCreateOfflineTts(&c)
                } }
            } } }
        } }
        guard let created else { throw LoadError.createFailed }
        tts = created; self.accent = accent
        sampleRate = Int(SherpaOnnxOfflineTtsSampleRate(created))
    }

    deinit { SherpaOnnxDestroyOfflineTts(tts) }

    /// Mono float samples in [-1, 1] at `sampleRate`. Empty on failure.
    public func synthesize(_ text: String, voice: KokoroVoice, speed: Float = 1.0) async -> [Float] {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.synthesizeNow(text, voice: voice, speed: speed)) }
        }
    }

    /// The blocking form, for tools and tests.
    public func synthesizeNow(_ text: String, voice: KokoroVoice, speed: Float = 1.0) -> [Float] {
        text.withCString { cText in
            var g = SherpaOnnxGenerationConfig()
            g.sid = voice.speakerID
            g.speed = speed
            g.silence_scale = 0.2
            guard let audio = SherpaOnnxOfflineTtsGenerateWithConfig(tts, cText, &g, nil, nil) else { return [] }
            defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
            let n = Int(audio.pointee.n)
            guard n > 0, let s = audio.pointee.samples else { return [] }
            return Array(UnsafeBufferPointer(start: s, count: n))
        }
    }
}
