import Foundation
import AVFoundation
import KokoroTTS
import VoiceKit

/// Loads the Kokoro model off the main thread and keeps one engine, for the accent in use, for the life of the app.
/// The model is downloaded on demand into Application Support (VoiceLibrary); a developer build may also carry one in
/// Contents/Resources/Kokoro.
@MainActor
final class KokoroRuntime {
    static let shared = KokoroRuntime()
    static let store = KokoroStore.standard

    /// Where the model is, or nil when Kokoro is not installed. Re-read with `refresh()` after an install or removal.
    private(set) static var directory: URL? = locate()
    static var isAvailable: Bool { directory != nil }

    private static func locate() -> URL? {
        if store.isInstalled { return store.directory }
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Kokoro", isDirectory: true),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("voices.bin").path) else { return nil }
        return dir
    }

    /// Picks up a new install (or its removal) and drops the loaded engine.
    static func refresh() {
        directory = locate()
        shared.loading = nil
    }

    private var loading: (accent: KokoroVoice.Accent, task: Task<KokoroEngine?, Never>)?

    /// The engine for `accent`, loading it on first use (about a second). Nil when the model is missing or broken.
    func engine(for accent: KokoroVoice.Accent) async -> KokoroEngine? {
        if let loading, loading.accent == accent { return await loading.task.value }
        guard let dir = Self.directory else { return nil }
        let task = Task.detached(priority: .userInitiated) { () -> KokoroEngine? in
            do { return try KokoroEngine(directory: dir, accent: accent, threads: 4) } catch {
                NSLog("Kokoro failed to load: %@", String(describing: error))
                return nil
            }
        }
        loading = (accent, task)    // the other accent's engine (if any) is released
        return await task.value
    }
}

/// Synthesizes narration chunks one at a time, most wanted first, and keeps the recent results.
@MainActor
private final class KokoroSynthQueue {
    struct Key: Hashable { var voice: KokoroVoice; var text: String }

    private var results: [Key: [Float]] = [:]
    private var order: [Key] = []                    // results, oldest first
    private var wanted: [Key] = []                   // not yet synthesized, in priority order
    private var waiters: [Key: [CheckedContinuation<[Float]?, Never>]] = [:]
    private var working: Key?
    private(set) var sampleRate = 24_000

    /// Replaces the prefetch list (stale prefetches are dropped, the chunk being synthesized finishes).
    func want(_ keys: [Key]) {
        wanted = keys.filter { results[$0] == nil && $0 != working }
        pump()
    }

    /// The samples for `key`, synthesizing it next. Nil when Kokoro is unavailable.
    func audio(_ key: Key) async -> [Float]? {
        if let r = results[key] { return r }
        wanted.removeAll { $0 == key }
        if key != working { wanted.insert(key, at: 0) }
        return await withCheckedContinuation { c in
            waiters[key, default: []].append(c)
            pump()
        }
    }

    /// Puts `keys` at the front of the queue, in order.
    func prioritize(_ keys: [Key]) {
        let fresh = keys.filter { results[$0] == nil && $0 != working }
        wanted.removeAll { fresh.contains($0) }
        wanted.insert(contentsOf: fresh, at: 0)
        pump()
    }

    private func pump() {
        guard working == nil, !wanted.isEmpty else { return }
        let key = wanted.removeFirst()
        working = key
        Task {
            let engine = await KokoroRuntime.shared.engine(for: key.voice.accent)
            let samples = await engine?.synthesize(key.text, voice: key.voice)
            if let engine { sampleRate = engine.sampleRate }
            working = nil
            if let samples {
                results[key] = samples; order.append(key)
                while order.count > 24 { results[order.removeFirst()] = nil }
            } else {
                wanted.removeAll()                    // no engine: fail everything queued
            }
            for c in waiters.removeValue(forKey: key) ?? [] { c.resume(returning: samples) }
            if samples == nil { for (_, cs) in waiters { cs.forEach { $0.resume(returning: nil) } }; waiters = [:] }
            pump()
        }
    }
}

/// Speaks with Kokoro: the text is cut into sentences, the first is played as soon as it is synthesized and the
/// rest are synthesized while earlier ones play, through AVAudioEngine.
@MainActor
final class KokoroNarrator {
    enum Outcome { case finished, stopped, unavailable }

    private let queue = KokoroSynthQueue()
    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var generation = 0
    private var pending = 0
    private var feedingDone = false
    private var waiting: CheckedContinuation<Outcome, Never>?
    private var feeder: Task<Void, Never>?

    private(set) var isSpeaking = false

    init() {
        audioEngine.attach(player)
    }

    static func chunks(_ text: String) -> [String] { SentenceSplitter.chunks(NarrationText.spoken(text)) }

    func prepare(_ texts: [String], voice: KokoroVoice) {
        queue.want(texts.flatMap(Self.chunks).map { .init(voice: voice, text: $0) })
    }

    func speak(_ text: String, voice: KokoroVoice) async -> Outcome {
        stop()
        guard KokoroRuntime.isAvailable else { return .unavailable }
        generation += 1
        let gen = generation
        let keys = Self.chunks(text).map { KokoroSynthQueue.Key(voice: voice, text: $0) }
        guard !keys.isEmpty else { return .finished }
        queue.prioritize(keys)
        pending = 0; feedingDone = false
        isSpeaking = true
        defer { if gen == generation { isSpeaking = false } }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Outcome, Never>) in
                waiting = c
                feeder = Task { [weak self] in
                    for (i, key) in keys.enumerated() {
                        guard let self else { return }
                        let samples = await self.queue.audio(key)
                        guard gen == self.generation else { return }
                        guard let samples else {
                            // Kokoro could not load: let the caller fall back, unless part of it was already heard.
                            self.end(gen, i == 0 ? .unavailable : .finished); return
                        }
                        self.schedule(samples, gen: gen)
                    }
                    guard let self, gen == self.generation else { return }
                    self.feedingDone = true
                    if self.pending == 0 { self.end(gen, .finished) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        generation += 1
        feeder?.cancel(); feeder = nil
        if audioEngine.isRunning { player.stop(); audioEngine.stop() }
        isSpeaking = false
        let c = waiting; waiting = nil
        c?.resume(returning: .stopped)
    }

    private func schedule(_ samples: [Float], gen: Int) {
        guard !samples.isEmpty else { return }
        let rate = Double(queue.sampleRate)
        if format?.sampleRate != rate {
            format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
            if audioEngine.isRunning { audioEngine.stop() }
            if let format { audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format) }
        }
        guard let format, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { dst.update(from: $0.baseAddress!, count: samples.count) }
        if !audioEngine.isRunning {
            do { try audioEngine.start() } catch { NSLog("Kokoro audio failed: %@", String(describing: error)); return }
        }
        pending += 1
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in self?.played(gen) }
        }
        if !player.isPlaying { player.play() }
    }

    private func played(_ gen: Int) {
        guard gen == generation else { return }
        pending -= 1
        if feedingDone && pending == 0 { end(gen, .finished) }
    }

    private func end(_ gen: Int, _ outcome: Outcome) {
        guard gen == generation else { return }
        feeder = nil
        if audioEngine.isRunning { player.stop(); audioEngine.stop() }
        isSpeaking = false
        let c = waiting; waiting = nil
        c?.resume(returning: outcome)
    }
}

extension KokoroNarrator: Narrator {
    private var settingsVoice: KokoroVoice {
        if case .kokoro(let v) = NarrationSettings.shared.voice { return v }
        return .default
    }
    func speak(_ text: String) async { _ = await speak(text, voice: settingsVoice) }
    func prepare(_ texts: [String]) { prepare(texts, voice: settingsVoice) }
}
