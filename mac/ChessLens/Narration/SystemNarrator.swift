import Foundation
import AVFoundation

/// Speaks with the system voice and returns when the utterance ends (or is stopped / the task cancelled).
@MainActor
final class SystemNarrator: NSObject, Narrator, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var waiting: CheckedContinuation<Void, Never>?
    private var utterance: AVSpeechUtterance?

    var isSpeaking: Bool { synth.isSpeaking }

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String) async {
        stop()
        let u = AVSpeechUtterance(string: NarrationText.spoken(text))
        u.voice = AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        u.postUtteranceDelay = 0.1
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                waiting = c
                utterance = u
                synth.speak(u)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        resume()
    }

    private func resume() {
        let c = waiting; waiting = nil; utterance = nil
        c?.resume()
    }

    /// A late didCancel from a stopped utterance must not end the next one.
    private func ended(_ id: ObjectIdentifier) {
        if let utterance, ObjectIdentifier(utterance) == id { resume() }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor [weak self] in self?.ended(id) }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        let id = ObjectIdentifier(u)
        Task { @MainActor [weak self] in self?.ended(id) }
    }
}
