import Foundation

/// The Kokoro v1.0 voices the app offers. Speaker ids index `voices.bin` of kokoro-int8-multi-lang-v1_0 (the model's
/// `speaker2id` metadata); grades are from Kokoro-82M's VOICES.md.
public enum KokoroVoice: String, CaseIterable, Sendable, Codable {
    case heart = "af_heart"      // A, the reference American voice
    case bella = "af_bella"      // A-
    case emma = "bf_emma"        // B-, best British voice
    case michael = "am_michael"  // C+, best American male voice

    public static let `default` = KokoroVoice.heart

    public var speakerID: Int32 {
        switch self {
        case .heart: 3
        case .bella: 2
        case .emma: 21
        case .michael: 16
        }
    }

    public var displayName: String {
        switch self {
        case .heart: "Heart (US)"
        case .bella: "Bella (US)"
        case .emma: "Emma (UK)"
        case .michael: "Michael (US)"
        }
    }

    public var accent: Accent { rawValue.hasPrefix("b") ? .british : .american }

    public enum Accent: String, Sendable {
        case american = "en-us", british = "en"   // espeak-ng voice names; plain "en" is British English
        var lexicon: String { self == .american ? "lexicon-us-en.txt" : "lexicon-gb-en.txt" }
    }
}
