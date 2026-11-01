import Foundation

/// An installed system voice, as far as choosing one is concerned (mapped from AVSpeechSynthesisVoice by the app).
public struct SystemVoiceInfo: Hashable, Sendable, Identifiable {
    /// AVSpeechSynthesisVoiceQuality's raw values: default 1, enhanced 2, premium 3.
    public enum Quality: Int, Comparable, Sendable, CaseIterable {
        case standard = 1, enhanced = 2, premium = 3
        public static func < (a: Quality, b: Quality) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .standard: "Standard"
            case .enhanced: "Enhanced"
            case .premium: "Premium"
            }
        }
    }

    public var id: String          // AVSpeechSynthesisVoice.identifier
    public var name: String
    public var language: String    // BCP 47, e.g. "en-US"
    public var quality: Quality
    public var isNovelty: Bool     // Bells, Zarvox and friends

    public init(id: String, name: String, language: String, quality: Quality, isNovelty: Bool = false) {
        self.id = id; self.name = name; self.language = language; self.quality = quality; self.isNovelty = isNovelty
    }

    /// "Ava (Premium)", "Samantha".
    public var displayName: String { quality == .standard ? name : "\(name) (\(quality.label))" }
    public var isEnglish: Bool { language.lowercased().hasPrefix("en") }
    /// Novelty voices and the Eloquence ones (Eddy, Flo, Grandpa...) are not fit to teach chess with.
    public var isNarrationGrade: Bool { !isNovelty && !id.contains(".eloquence.") && !id.contains(".speech.synthesis.voice.") }
}

/// Picks the voice lessons are read in when the user has not chosen one: the best-sounding installed English voice.
public enum SystemVoicePicker {
    /// The voices Apple ships in Premium quality for English; Ava is the one we point people at.
    public static let recommendedPremium = "Ava"

    /// English, narration-grade voices, best first: by quality, then the user's own English variant (en-GB for a
    /// British Mac), then US English, then Ava, then name.
    public static func ranked(_ voices: [SystemVoiceInfo], preferredLanguage: String = "en-US") -> [SystemVoiceInfo] {
        let pref = preferredLanguage.replacingOccurrences(of: "_", with: "-").lowercased()
        func langScore(_ v: SystemVoiceInfo) -> Int {
            let l = v.language.lowercased()
            if pref.hasPrefix("en"), l == pref { return 2 }
            return l == "en-us" ? 1 : 0
        }
        return voices.filter { $0.isEnglish && $0.isNarrationGrade }.sorted { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            if langScore(a) != langScore(b) { return langScore(a) > langScore(b) }
            let aAva = a.name == recommendedPremium, bAva = b.name == recommendedPremium
            if aAva != bAva { return aAva }
            if a.name != b.name { return a.name < b.name }
            return a.id < b.id
        }
    }

    /// The best English voice, or nil when none is installed (the app then lets AVSpeechSynthesizer pick).
    public static func best(_ voices: [SystemVoiceInfo], preferredLanguage: String = "en-US") -> SystemVoiceInfo? {
        ranked(voices, preferredLanguage: preferredLanguage).first
    }

    /// English voices grouped by quality, Premium first, each group ranked as above. Empty groups are left out.
    public static func grouped(_ voices: [SystemVoiceInfo], preferredLanguage: String = "en-US") -> [(quality: SystemVoiceInfo.Quality, voices: [SystemVoiceInfo])] {
        let r = ranked(voices, preferredLanguage: preferredLanguage)
        return SystemVoiceInfo.Quality.allCases.reversed().compactMap { q in
            let vs = r.filter { $0.quality == q }
            return vs.isEmpty ? nil : (q, vs)
        }
    }

    /// True when some English Premium voice is installed (so there is nothing better to send the user to get).
    public static func hasPremium(_ voices: [SystemVoiceInfo]) -> Bool {
        voices.contains { $0.isEnglish && $0.isNarrationGrade && $0.quality == .premium }
    }
}
