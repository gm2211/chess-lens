import Foundation
import KokoroTTS

// Headless Kokoro check: kokoro-check <model-dir> <out.wav> [voice] [text]
// Loads the model, synthesizes the text sentence by sentence and writes a WAV. Prints load time, time to first audio
// (first sentence ready), duration and RMS. Never plays anything.
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: kokoro-check <model-dir> <out.wav> [voice] [text]"); exit(2) }
let dir = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
let voice = args.count > 3 ? KokoroVoice(rawValue: args[3]) ?? .default : .default
let text = args.count > 4 ? args[4] : "White's bishop pins the knight on d7 to the king."

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
let t0 = now()
let engine: KokoroEngine
do { engine = try KokoroEngine(directory: dir, accent: voice.accent, threads: Int(ProcessInfo.processInfo.environment["KOKORO_THREADS"] ?? "") ?? 4) } catch { print("LOAD FAILED: \(error)"); exit(1) }
let t1 = now()
print(String(format: "loaded model in %.2f s (sample rate %d Hz, voice %@)", t1 - t0, engine.sampleRate, voice.rawValue))

var all: [Float] = []
for (i, s) in SentenceSplitter.chunks(text).enumerated() {
    let a = now()
    let samples = engine.synthesizeNow(s, voice: voice)
    let secs = Double(samples.count) / Double(engine.sampleRate)
    print(String(format: "chunk %d \"%@\": %.3f s synth for %.2f s audio (RTF %.2f)%@", i + 1, s, now() - a, secs,
                 (now() - a) / max(secs, 0.001), i == 0 ? "  <- time to first audio" : ""))
    all += samples
}
// A warm second run of the first sentence (the first inference also pays onnxruntime's one-off setup).
let w = now(); _ = engine.synthesizeNow(SentenceSplitter.chunks(text).first ?? text, voice: voice)
print(String(format: "warm first-sentence synth: %.3f s", now() - w))

let duration = Double(all.count) / Double(engine.sampleRate), rms = WAV.rms(all)
try WAV.data(all, sampleRate: engine.sampleRate).write(to: out)
print(String(format: "wrote %@: duration %.2f s, RMS %.4f", out.path, duration, rms))
exit(duration > 0.5 && rms > 0.005 ? 0 : 1)
