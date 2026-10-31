import XCTest
@testable import ChessCore

final class AskPromptTests: XCTestCase {
    /// 1. e4 e5 2. Nf3 Nc6, looking at the position after 2…Nc6.
    private func subject(review: Bool, history: [String]? = nil) throws -> AskPrompt.Subject {
        let g = PGN.parse("1. e4 e5 2. Nf3 Nc6 *")[0].game
        let n = g.nodes
        var s = AskPrompt.Subject(position: n[4].position, before: n[3].position, move: try XCTUnwrap(n[4].move),
                                  history: history ?? ["e4", "e5", "Nf3", "Nc6"])
        if review {
            s.classification = "mistake"
            s.evalBefore = .cp(30); s.evalNow = .cp(150)
            s.tags = [.allowsFork]
            s.line = ["f1b5", "g8f6"]
            s.best = ["b8c6", "f1b5", "a7a6"]
        }
        return s
    }

    func testPromptWithReviewData() throws {
        let s = try subject(review: true)
        let p = AskPrompt.user(s, turns: [], question: "  Why not Nf6?  ")
        XCTAssertTrue(p.contains("Position (FEN): \(s.position.fen)"))
        XCTAssertTrue(p.contains("Side to move: White"))
        XCTAssertTrue(p.contains("Move just played: 2\u{2026} Nc6 (mistake)"))
        XCTAssertTrue(p.contains("Position before that move (FEN): \(try XCTUnwrap(s.before).fen)"))
        // Black moved: White-POV +0.30 / +1.50 becomes -0.30 / -1.50.
        XCTAssertTrue(p.contains("-0.30 before, -1.50 after"))
        XCTAssertTrue(p.contains("allows a fork"))
        XCTAssertTrue(p.contains("Engine line from here: 3. Bb5 Nf6"))
        XCTAssertTrue(p.contains("instead of the move just played: 2\u{2026} Nc6 3. Bb5 a6"))
        XCTAssertTrue(p.contains("Game so far: 1. e4 e5 2. Nf3 Nc6"))
        XCTAssertTrue(p.hasSuffix("Player's question about the position above: Why not Nf6?"))
        XCTAssertFalse(p.contains("Earlier in this conversation"))
    }

    func testPromptWithoutReviewData() throws {
        let p = AskPrompt.user(try subject(review: false), turns: [], question: "Plan?")
        XCTAssertTrue(p.contains("Move just played: 2\u{2026} Nc6\n"))
        XCTAssertFalse(p.contains("Evaluation"))
        XCTAssertFalse(p.contains("Tags:"))
        XCTAssertFalse(p.contains("Engine line"))
        XCTAssertFalse(p.contains("preferred line"))
    }

    func testRootPositionWithEvalOnly() {
        var s = AskPrompt.Subject(position: .start)
        s.evalNow = .cp(25); s.line = ["e2e4", "e7e5"]
        let p = AskPrompt.user(s, turns: [], question: "Which opening?")
        XCTAssertFalse(p.contains("Move just played"))
        XCTAssertTrue(p.contains("side to move (for your understanding, don't quote it): +0.25"))
        XCTAssertTrue(p.contains("Engine line from here: 1. e4 e5"))
        XCTAssertTrue(p.contains("Game so far: (start of game)"))
    }

    func testHistoryTruncation() throws {
        // 30 plies of history; only the last 16 are shown, numbered from the right ply.
        var s = try subject(review: false)
        var pos = Position.start
        var all: [String] = []
        for i in 0..<30 {
            let moves = pos.legalMoves()
            let m = moves[i % moves.count]
            all.append(pos.san(m)); pos = pos.applyingUnchecked(m)
        }
        s.position = pos; s.history = all
        s.before = nil; s.move = nil
        let p = AskPrompt.user(s, turns: [], question: "q")
        let line = try XCTUnwrap(p.split(separator: "\n").first { $0.hasPrefix("Game so far:") })
        XCTAssertTrue(line.hasPrefix("Game so far: \u{2026} "))
        XCTAssertTrue(line.contains("8. "))                    // ply 15 starts move 8
        XCTAssertFalse(line.contains(" 7. "))
        let compact = AskPrompt.user(s, turns: [], question: "q", compact: true)
        let cline = try XCTUnwrap(compact.split(separator: "\n").first { $0.hasPrefix("Game so far:") })
        XCTAssertTrue(cline.count < line.count)
        XCTAssertTrue(cline.contains("12. "))
        XCTAssertFalse(cline.contains(" 11. "))
    }

    func testConversationTruncation() throws {
        let s = try subject(review: false)
        let turns = (1...6).map {
            AskPrompt.Turn(context: "After \($0)", question: "Question \($0)",
                           answer: String(repeating: "word ", count: 200))
        }
        let p = AskPrompt.user(s, turns: turns, question: "Latest")
        XCTAssertFalse(p.contains("Question 2"))
        for i in 3...6 { XCTAssertTrue(p.contains("Question \(i)")) }
        XCTAssertTrue(p.contains("(board then: After 6)"))
        XCTAssertFalse(p.contains(String(repeating: "word ", count: 150)))
        XCTAssertTrue(p.contains("\u{2026}\n"))
        let compact = AskPrompt.user(s, turns: turns, question: "Latest", compact: true)
        XCTAssertFalse(compact.contains("Question 4"))
        XCTAssertTrue(compact.contains("Question 5") && compact.contains("Question 6"))
        XCTAssertTrue(compact.count < p.count)
        // The compact prompt leaves out the second FEN and the tags.
        let c2 = AskPrompt.user(try subject(review: true), turns: [], question: "q", compact: true)
        XCTAssertFalse(c2.contains("Position before that move"))
        XCTAssertFalse(c2.contains("Tags:"))
    }

    func testSystemPrompt() {
        XCTAssertTrue(AskPrompt.system(tool: true).contains("<engine fen="))
        XCTAssertFalse(AskPrompt.system(tool: false).contains("<engine fen="))
        XCTAssertTrue(AskPrompt.system(tool: false).contains("40 to 150 words"))
        XCTAssertTrue(AskPrompt.system(tool: false, compact: true).contains("40 to 100 words"))
    }

    func testContextLabelAndStarters() throws {
        let g = PGN.parse("1. e4 e5 2. Nf3 Nc6 *")[0].game
        let n = g.nodes
        XCTAssertEqual(AskPrompt.contextLabel(position: n[4].position, before: n[3].position, move: n[4].move),
                       "After 2\u{2026}Nc6 \u{00B7} White to move")
        XCTAssertEqual(AskPrompt.contextLabel(position: n[3].position, before: n[2].position, move: n[3].move),
                       "After 2.Nf3 \u{00B7} Black to move")
        XCTAssertEqual(AskPrompt.contextLabel(position: .start, before: nil, move: nil), "Start of the game \u{00B7} White to move")
        XCTAssertEqual(AskPrompt.starters(classification: nil, isError: false, bestAlternative: nil),
                       ["What's the plan here?", "What should I be careful about?"])
        let full = AskPrompt.starters(classification: "blunder", isError: true, bestAlternative: "Nf6")
        XCTAssertEqual(full.first, "Why was this a mistake?")
        XCTAssertEqual(full.last, "Why not Nf6 instead?")
        XCTAssertEqual(AskPrompt.starters(classification: "great move", isError: false, bestAlternative: nil).first,
                       "Why was this a good move?")
    }

    func testCitedMoves() {
        XCTAssertEqual(Set(AskPrompt.citedMoves(in: ["Why not Nf6?", "Because 12. O-O-O is risky"]).map(Grounding.normalize)),
                       ["Nf6", "O-O-O"])
    }
}
