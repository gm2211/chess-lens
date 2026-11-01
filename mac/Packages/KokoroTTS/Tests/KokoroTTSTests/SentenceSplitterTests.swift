import Testing
@testable import KokoroTTS

@Test func splitsSentences() {
    #expect(SentenceSplitter.split("The knight jumps. Then the queen takes on d7!") == ["The knight jumps.", "Then the queen takes on d7!"])
}

@Test func gluesShortFragments() {
    #expect(SentenceSplitter.split("Yes. The bishop is pinned.") == ["Yes. The bishop is pinned."])
}

@Test func keepsTextWithoutPunctuation() {
    #expect(SentenceSplitter.split("castles long") == ["castles long"])
}

@Test func cutsLongFirstSentenceAtClause() {
    #expect(SentenceSplitter.chunks("After the exchange on d7, the king stands alone in the centre. Rook to e1.")
            == ["After the exchange on d7,", "the king stands alone in the centre.", "Rook to e1."])
    #expect(SentenceSplitter.chunks("White's bishop pins the knight on d7 to the king.") == ["White's bishop pins the knight on d7 to the king."])
}
