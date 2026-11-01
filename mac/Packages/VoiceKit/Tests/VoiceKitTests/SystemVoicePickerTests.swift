import Testing
@testable import VoiceKit

private func v(_ name: String, _ lang: String = "en-US", _ q: SystemVoiceInfo.Quality = .standard, novelty: Bool = false,
               id: String? = nil) -> SystemVoiceInfo {
    SystemVoiceInfo(id: id ?? "com.apple.voice.\(q).\(lang).\(name)", name: name, language: lang, quality: q, isNovelty: novelty)
}

@Test func premiumBeatsEnhancedBeatsStandard() {
    let voices = [v("Samantha"), v("Zoe", "en-US", .enhanced), v("Ava", "en-US", .premium), v("Tom", "en-US", .enhanced)]
    #expect(SystemVoicePicker.best(voices)?.name == "Ava")
    #expect(SystemVoicePicker.best(voices.filter { $0.quality != .premium })?.name == "Tom")   // Tom < Zoe
    #expect(SystemVoicePicker.best([v("Samantha"), v("Alex")])?.name == "Alex")
}

@Test func onlyEnglishNarrationVoices() {
    let voices = [v("Amélie", "fr-CA", .premium), v("Zarvox", novelty: true), v("Bells", "en-US", .premium, novelty: true),
                  v("Grandpa", id: "com.apple.eloquence.en-US.Grandpa"), v("Fred", id: "com.apple.speech.synthesis.voice.Fred"),
                  v("Samantha")]
    #expect(SystemVoicePicker.best(voices)?.name == "Samantha")
    #expect(SystemVoicePicker.ranked(voices).map(\.name) == ["Samantha"])
    #expect(SystemVoicePicker.best([v("Amélie", "fr-FR", .premium)]) == nil)
    #expect(SystemVoicePicker.best([]) == nil)
}

@Test func prefersTheUsersEnglishThenUSThenAva() {
    let voices = [v("Daniel", "en-GB", .enhanced), v("Ava", "en-US", .enhanced), v("Karen", "en-AU", .enhanced), v("Allison", "en-US", .enhanced)]
    #expect(SystemVoicePicker.best(voices, preferredLanguage: "en_GB")?.name == "Daniel")
    #expect(SystemVoicePicker.best(voices, preferredLanguage: "en-US")?.name == "Ava")        // Ava ahead of Allison
    #expect(SystemVoicePicker.best(voices, preferredLanguage: "it-IT")?.name == "Ava")        // non-English Mac: US English
    // Quality still wins over language.
    #expect(SystemVoicePicker.best(voices + [v("Lee", "en-AU", .premium)], preferredLanguage: "en-GB")?.name == "Lee")
}

@Test func groupsByQualityPremiumFirst() {
    let voices = [v("Samantha"), v("Ava", "en-US", .premium), v("Zoe", "en-US", .premium), v("Tom", "en-US", .enhanced), v("Thomas", "fr-FR")]
    let g = SystemVoicePicker.grouped(voices)
    #expect(g.map(\.quality) == [.premium, .enhanced, .standard])
    #expect(g[0].voices.map(\.name) == ["Ava", "Zoe"])
    #expect(SystemVoicePicker.grouped([v("Samantha")]).map(\.quality) == [.standard])
}

@Test func premiumDetectionAndNames() {
    #expect(SystemVoicePicker.hasPremium([v("Ava", "en-US", .premium)]))
    #expect(!SystemVoicePicker.hasPremium([v("Ava", "en-US", .enhanced), v("Amélie", "fr-FR", .premium)]))
    #expect(v("Ava", "en-US", .premium).displayName == "Ava (Premium)")
    #expect(v("Samantha").displayName == "Samantha")
}
