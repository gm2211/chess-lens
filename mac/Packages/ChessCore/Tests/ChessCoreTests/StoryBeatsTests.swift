import XCTest
@testable import ChessCore

final class StoryBeatsTests: XCTestCase {
    var sans: [String] { PGN.parse(MomentPickerTests.opera)[0].game.mainlineSAN }
    var line: LessonLine { LessonLine(start: .start, sans: sans) }

    // MARK: Schema

    func testParseBeats() {
        let json = """
        {"headline": "H", "beats": [
          {"kind": "turning point", "at": "9...b5", "title": "The slip", "headline": "Black grabs space.", "explain": "It opens lines.", "rule": "Develop first.", "arrows": ["c3b5", "zz"], "circles": ["b5", "x9"]},
          {"type": "ending", "move": "17. Rd8#", "summary": "Mate."},
          {"kind": "weird", "at": "6. Bc4", "explain": "Only text."},
          {"kind": "slip", "at": "6. Bc4"}
        ]}
        """
        let g = GameLesson.parse(json)!
        XCTAssertEqual(g.beats.count, 3)                                     // the last has no text
        XCTAssertEqual(g.beats[0].kind, .turning)
        XCTAssertEqual(g.beats[0].title, "The slip")
        XCTAssertEqual(g.beats[0].arrows.map(\.uci), ["c3b5"])
        XCTAssertEqual(g.beats[0].circles, [Sq.parse("b5")!])
        XCTAssertEqual(g.beats[1].kind, .finish)
        XCTAssertEqual(g.beats[1].title, "The finish")                      // default title
        XCTAssertEqual(g.beats[1].at, "17. Rd8#")
        XCTAssertEqual(g.beats[2].kind, .idea)
        XCTAssertEqual(g.beats[0].narration, "Black grabs space. It opens lines. Rule of thumb: Develop first.")
    }

    func testBeatsOnlyAnswerIsNotRaw() {
        let g = GameLesson.parse(#"{"beats": [{"kind": "setup", "at": "start", "headline": "Calm start"}]}"#)!
        XCTAssertNil(g.story)
        XCTAssertEqual(g.beats.count, 1)
    }

    // MARK: Grounding

    func testGroundedBeatsOrderPruneAndDrop() {
        let beats: [GameLesson.Beat] = [
            .init(kind: .finish, at: "17. Rd8#", headline: "Mate on d8.", explain: "The rook lands. Then 18. Qh7 follows."),
            .init(kind: .slip, at: "9...b5", headline: "Black plays 22. Qxh8 here.", explain: "Lines open. The knight jumps in with 10. Nxb5."),
            .init(kind: .idea, at: "99. Kh1", headline: "Not in the game."),
            .init(kind: .setup, at: "start", headline: "Both sides develop."),
            .init(kind: .punish, at: "9...b5", headline: "Same ply twice."),
        ]
        let allowed = Grounding.allowed(sans)
        let g = GameLesson.groundedBeats(beats, allowed: allowed, line: line)
        XCTAssertEqual(g.map(\.kind), [.setup, .slip, .finish])
        XCTAssertEqual(g.map(\.ply), [0, 18, 33])
        XCTAssertEqual(g[2].explain, "The rook lands.")                     // invented 18. Qh7 dropped
        // The headline cited an invented move: it is replaced by the explanation's first sentence.
        XCTAssertEqual(g[1].headline, "Lines open.")
        XCTAssertEqual(g[1].explain, "The knight jumps in with 10. Nxb5.")
    }

    func testGroundedBeatsCap() {
        let beats = (1...9).map { i in GameLesson.Beat(kind: .idea, at: "\(i). \(sans[(i - 1) * 2])", headline: "Beat \(i).") }
        let g = GameLesson.groundedBeats(beats, allowed: Grounding.allowed(sans), line: line)
        XCTAssertEqual(g.count, GameLesson.Beat.maxBeats)
        XCTAssertEqual(g.map(\.ply), [1, 3, 5, 7, 9, 11])
    }

    func testLessonGroundingKeepsBeats() {
        var g = GameLesson(headline: "H")
        g.beats = [.init(kind: .turning, at: "10. Nxb5", headline: "The knight strikes.")]
        let r = g.grounded(allowed: Grounding.allowed(sans), line: line)
        XCTAssertEqual(r.lesson.beats.first?.ply, 19)
    }

    // MARK: Fallback

    var moments: [BeatMoment] {
        [BeatMoment(ply: 8, side: .black, severity: 1, classification: "inaccuracy", best: "b8c6", reply: "d1f3"),
         BeatMoment(ply: 18, side: .black, severity: 3, classification: "blunder", best: "b8d7", reply: "c3b5"),
         BeatMoment(ply: 14, side: .black, severity: 2, classification: "mistake", best: "b8c6", reply: "b3b7"),
         BeatMoment(ply: 21, side: .white, severity: 0, classification: "great move")]
    }

    func testFallbackFromMoments() {
        let b = StoryBeats.fallback(lesson: nil, moments: moments, line: line)
        XCTAssertEqual(b.map(\.kind), [.setup, .slip, .slip, .turning, .punish, .finish])
        XCTAssertEqual(b.map(\.ply), [6, 8, 14, 18, 19, 33])
        XCTAssertEqual(b.map(\.at), ["3...Bg4", "4...Bxf3", "7...Qe7", "9...b5", "10. Nxb5", "17. Rd8#"])
        let t = b[3]
        XCTAssertEqual(t.title, "The turning point")
        XCTAssertEqual(t.headline, "Black's 9\u{2026}b5 is a blunder.")
        XCTAssertEqual(t.explain, "Stronger was 9\u{2026}Nbd7. It allows 10. Nxb5.")
        XCTAssertEqual(t.rule, StoryBeats.genericRule(severity: 3))
        XCTAssertEqual(t.arrows.map(\.uci), ["c3b5"])
        XCTAssertEqual(b[4].headline, "White punishes it with 10. Nxb5.")
        XCTAssertEqual(b[5].headline, "Checkmate ends the game.")
        XCTAssertEqual(b[1].headline, "Black's 4\u{2026}Bxf3 is an inaccuracy.")
        // Every beat resolves back to its own ply.
        for beat in b { XCTAssertEqual(line.ply(of: beat.at), beat.ply) }
        // Deterministic.
        XCTAssertEqual(b, StoryBeats.fallback(lesson: nil, moments: moments.reversed(), line: line))
    }

    func testFallbackUsesLessonAndCaps() {
        var lesson = GameLesson(story: "White develops quickly. Black grabs pawns.", lessons: ["Develop first", "Castle early"])
        lesson.concepts = [.init(name: "king safety in the centre now", explanation: "An uncastled king is a target. More.",
                                 story: [.init(at: "12. O-O-O", say: "White castles into the attack.", ply: 23)])]
        // All three errors: six beats already, so the idea is cut.
        let full = StoryBeats.fallback(lesson: lesson, moments: moments, line: line)
        XCTAssertEqual(full.count, 6)
        XCTAssertFalse(full.contains { $0.kind == .idea })
        XCTAssertEqual(full[0].headline, "White develops quickly.")
        XCTAssertEqual(full[0].explain, "Black grabs pawns.")
        XCTAssertEqual(full[1].rule, "Develop first.")
        XCTAssertEqual(full[2].rule, "Castle early.")
        // One error: room for the idea.
        let one = StoryBeats.fallback(lesson: lesson, moments: [moments[1]], line: line)
        XCTAssertEqual(one.map(\.kind), [.setup, .turning, .punish, .idea, .finish])
        XCTAssertEqual(one.map(\.ply), [10, 18, 19, 23, 33])
        let idea = one[3]
        XCTAssertEqual(idea.title, "King safety in the")
        XCTAssertEqual(idea.headline, "An uncastled king is a target.")
        XCTAssertEqual(idea.explain, "White castles into the attack.")
        XCTAssertEqual(one[1].rule, "Develop first.")
        XCTAssertEqual(one.last?.rule, "Castle early.")                    // the habit left over
    }

    func testFallbackCleanGameAndEmptyLine() {
        let b = StoryBeats.fallback(lesson: nil, moments: [], line: line)
        XCTAssertEqual(b.map(\.kind), [.setup, .finish])
        XCTAssertEqual(b.first?.ply, 10)
        XCTAssertTrue(StoryBeats.fallback(lesson: nil, moments: [], line: LessonLine(start: .start, sans: [])).isEmpty)
        // Early first error: the setup is the start position.
        let early = StoryBeats.fallback(lesson: nil, moments: [BeatMoment(ply: 2, side: .black, severity: 2, classification: "mistake")], line: line)
        XCTAssertEqual(early.first?.at, "start")
        XCTAssertEqual(early.first?.ply, 0)
    }

    func testBeatsPreferLesson() {
        var lesson = GameLesson()
        XCTAssertEqual(StoryBeats.beats(lesson: lesson, moments: moments, line: line).count, 6)
        lesson.beats = [.init(kind: .idea, at: "6. Bc4", headline: "x", ply: 11)]
        XCTAssertEqual(StoryBeats.beats(lesson: lesson, moments: moments, line: line).count, 1)
    }

    func testPromptMentionsBeats() {
        let s = SummaryPrompt.system(tool: false)
        XCTAssertTrue(s.contains("\"beats\""))
        XCTAssertTrue(s.contains("\"rule\""))
        XCTAssertTrue(s.contains("never evaluation numbers"))
    }

    // MARK: Judging

    func testJudgeThresholds() {
        let best = Eval.cp(150)
        XCTAssertEqual(BetterMove.judge(tried: "B8D7", side: .black, best: "b8d7", bestEval: best, played: "b7b5", triedEval: nil), .top)
        XCTAssertEqual(BetterMove.judge(tried: "b7b5", side: .black, best: "b8d7", bestEval: best, played: "b7b5", triedEval: .cp(150)), .gameMove)
        XCTAssertEqual(BetterMove.judge(tried: "h7h6", side: .black, best: "b8d7", bestEval: best, played: "b7b5", triedEval: nil), .unchecked)
        // Black at +1.50: a try at +1.80 loses ~2.5 points (fine); +3.20 loses ~13 (clearly worse).
        XCTAssertEqual(BetterMove.judge(tried: "h7h6", side: .black, best: "b8d7", bestEval: best, played: "b7b5", triedEval: .cp(180)), .good)
        if case .notQuite(let r, let l) = BetterMove.judge(tried: "h7h6", side: .black, best: "b8d7", bestEval: best, played: "b7b5",
                                                           triedEval: .cp(320), reply: "10. Nxb5") {
            XCTAssertEqual(r, "10. Nxb5"); XCTAssertGreaterThan(l, 10); XCTAssertLessThan(l, 20)
        } else { XCTFail() }
        // Better than the review's best still counts as fine.
        XCTAssertEqual(BetterMove.judge(tried: "h7h6", side: .black, best: "b8d7", bestEval: best, played: "b7b5", triedEval: .cp(-50)), .good)
        // White's side; a mate for White is never worse.
        XCTAssertEqual(BetterMove.judge(tried: "a2a3", side: .white, best: "e2e4", bestEval: .cp(300), played: "g2g4", triedEval: .mate(3)), .good)
        XCTAssertEqual(BetterMove.loss(side: .white, bestEval: .cp(0), triedEval: .cp(0)), 0)
        XCTAssertEqual(BetterMove.loss(side: .white, bestEval: .cp(0), triedEval: .mate(-2)), 50, accuracy: 0.001)
        // Exactly at the threshold is accepted.
        XCTAssertTrue(BetterMove.acceptLoss == 5)
    }

    func testJudgeWording() {
        XCTAssertEqual(BetterMove.text(.top), "Excellent \u{2014} that's the engine's top choice.")
        XCTAssertEqual(BetterMove.text(.good), "Good \u{2014} also fine.")
        XCTAssertEqual(BetterMove.text(.notQuite(reply: "10. Nxb5", loss: 7)), "Not quite \u{2014} after 10. Nxb5, it's a little worse than the best move.")
        XCTAssertEqual(BetterMove.text(.notQuite(reply: "10. Nxb5", loss: 15)), "Not quite \u{2014} after 10. Nxb5, it's clearly worse.")
        XCTAssertEqual(BetterMove.text(.notQuite(reply: nil, loss: 40)), "Not quite \u{2014} the position falls apart.")
        XCTAssertTrue(BetterMove.text(.gameMove).hasPrefix("That's the move from the game"))
        XCTAssertEqual(BetterMove.prompt(side: .black), "Find a better move for Black")
        XCTAssertTrue(BetterMove.Verdict.top.isCorrect)
        XCTAssertTrue(BetterMove.Verdict.good.isCorrect)
        XCTAssertFalse(BetterMove.Verdict.gameMove.isCorrect)
        XCTAssertFalse(BetterMove.Verdict.notQuite(reply: nil, loss: 6).isCorrect)
    }

    func testMoveLabel() {
        let before = line.position(atPly: 17)!
        XCTAssertEqual(StoryBeats.moveLabel("b8d7", from: before), "9\u{2026}Nbd7")
        XCTAssertEqual(StoryBeats.moveLabel("c3b5", from: line.position(atPly: 18)!), "10. Nxb5")
        XCTAssertNil(StoryBeats.moveLabel("a1a8", from: before))
    }
}
