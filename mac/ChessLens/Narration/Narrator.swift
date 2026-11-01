import Foundation
import Observation
import KokoroTTS
import VoiceKit

/// A lesson voice. `speak` returns when the narration has been heard to the end, or was stopped or its task
/// cancelled, which is what LessonPlayer's auto-advance waits on.
@MainActor
protocol Narrator: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String) async
    func stop()
    /// Hints which texts are coming (in order), so a slow voice can synthesize them ahead. Replaces earlier hints.
    func prepare(_ texts: [String])
}

extension Narrator {
    func prepare(_ texts: [String]) {}
}

/// The voice lessons are read in: a downloaded Kokoro voice, or a macOS system voice (nil = the best one installed,
/// which is the default, so a newly installed Premium voice is picked up on its own).
enum NarratorVoice: Hashable, Identifiable {
    case kokoro(KokoroVoice)
    case system(String?)

    static let bestSystem = NarratorVoice.system(nil)

    var id: String { storageValue }
    var storageValue: String {
        switch self {
        case .kokoro(let v): v.rawValue
        case .system(nil): "system"
        case .system(let id?): "system:" + id
        }
    }
    init?(storageValue: String) {
        if storageValue == "system" { self = .system(nil) }
        else if storageValue.hasPrefix("system:") { self = .system(String(storageValue.dropFirst("system:".count))) }
        else if let v = KokoroVoice(rawValue: storageValue) { self = .kokoro(v) }
        else { return nil }
    }

    var isKokoro: Bool { if case .kokoro = self { true } else { false } }
}

/// The chosen lesson voice, persisted in UserDefaults (`lesson.voice`).
@Observable @MainActor
final class NarrationSettings {
    static let shared = NarrationSettings()
    static let voiceKey = "lesson.voice"

    private let library = VoiceLibrary.shared

    /// What the user picked. May name a voice that is no longer installed; `effectiveVoice` is what is used.
    var voice: NarratorVoice {
        didSet { UserDefaults.standard.set(voice.storageValue, forKey: Self.voiceKey) }
    }

    private init() {
        voice = UserDefaults.standard.string(forKey: Self.voiceKey).flatMap(NarratorVoice.init(storageValue:)) ?? .bestSystem
    }

    /// The chosen voice if it is still installed, else the best system voice.
    var effectiveVoice: NarratorVoice {
        switch voice {
        case .kokoro: library.kokoroInstalled ? voice : .bestSystem
        case .system(let id?): library.systemVoices.contains { $0.id == id } ? voice : .bestSystem
        case .system(nil): voice
        }
    }

    /// The system voice identifier to speak with (nil: let AVSpeechSynthesizer pick for the current language).
    var systemVoiceID: String? {
        if case .system(let id?) = effectiveVoice { return id }
        return library.bestSystemVoice?.id
    }

    /// The voices the lesson bar offers: the best system voice, the specific system voice chosen in Settings (if
    /// any) and the Kokoro voices once downloaded.
    var menuVoices: [NarratorVoice] {
        var vs: [NarratorVoice] = [.bestSystem]
        if case .system(_?) = effectiveVoice { vs.append(effectiveVoice) }
        if library.kokoroInstalled { vs += KokoroVoice.allCases.map(NarratorVoice.kokoro) }
        return vs
    }

    func displayName(_ v: NarratorVoice) -> String {
        switch v {
        case .kokoro(let k): return k.displayName
        case .system(nil): return library.bestSystemVoice.map { "\($0.displayName), best system voice" } ?? "System voice"
        case .system(let id?): return library.systemVoices.first { $0.id == id }?.displayName ?? "System voice"
        }
    }
}

/// Notation read the way a coach would say it: "6...Nf6" becomes "6, knight f6".
enum NarrationText {
    static func spoken(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{2026}", with: "...")
        s = s.replacingOccurrences(of: "O-O-O", with: "castles long").replacingOccurrences(of: "O-O", with: "castles")
        let pieces: [Character: String] = ["K": "king", "Q": "queen", "R": "rook", "B": "bishop", "N": "knight"]
        let rx = try! NSRegularExpression(pattern: #"\b(\d{1,3})(\.\.\.|\.)\s?([KQRBN])?([a-h]?[1-8]?)(x)?([a-h][1-8])(=[QRBN])?([+#])?"#)
        let ns = s as NSString
        var out = "", last = 0
        for m in rx.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            var words = [g(1)! + ","]
            if let p = g(3)?.first { words.append(pieces[p] ?? "") }
            if let d = g(4), !d.isEmpty { words.append(d) }
            if g(5) != nil { words.append("takes") }
            words.append(g(6)!)
            if let promo = g(7)?.last { words.append("promotes to " + (pieces[promo] ?? "queen")) }
            if let c = g(8) { words.append(c == "#" ? "mate" : "check") }
            out += words.joined(separator: " ")
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// What LessonPlayer talks to: speaks with the voice chosen in NarrationSettings, falling back to the system voice
/// when Kokoro is not installed or fails to load.
@MainActor
final class VoiceNarrator: Narrator {
    private let settings = NarrationSettings.shared
    private lazy var system = SystemNarrator()
    private lazy var kokoro = KokoroNarrator()
    private var active: (any Narrator)?

    var isSpeaking: Bool { active?.isSpeaking ?? false }

    func speak(_ text: String) async {
        stop()
        if case .kokoro(let v) = settings.effectiveVoice {
            active = kokoro
            switch await kokoro.speak(text, voice: v) {
            case .finished, .stopped: return
            case .unavailable: if Task.isCancelled { return }   // fall through to the system voice
            }
        }
        active = system
        system.voiceID = settings.systemVoiceID
        await system.speak(text)
    }

    func stop() {
        active?.stop()
        active = nil
    }

    func prepare(_ texts: [String]) {
        if case .kokoro(let v) = settings.effectiveVoice { kokoro.prepare(texts, voice: v) }
    }
}
