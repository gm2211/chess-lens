import XCTest
@testable import ChessCore

final class PhaseTests: XCTestCase {
    func positions(_ pgn: String) -> (pos: [Position], plies: [Int]) {
        let g = PGN.parse(pgn)[0].game
        let line = g.mainline()
        return (line.map { g.nodes[$0].position }, line.map { g.nodes[$0].ply })
    }

    func testOpeningThenMiddlegameByPly() {
        let (p, plies) = positions("1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6 8. c3 O-O 9. h3 Nb8 10. d4 Nbd7 11. Nbd2 Bb7 12. Bc2 Re8 13. Nf1 Bf8 *")
        let ph = GamePhases.classify(p, plies: plies)
        XCTAssertEqual(ph[0], .opening)
        XCTAssertEqual(ph[10], .opening)
        XCTAssertEqual(ph[24], .middlegame)
        XCTAssertEqual(ph.last, .middlegame)
        XCTAssertTrue(zip(ph, ph.dropFirst()).allSatisfy { $0 <= $1 }, "phases only move forward")
    }

    func testQueenTradeEndsOpening() throws {
        let queens = try Position(fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2")
        XCTAssertEqual(queens.phase(ply: 3), .opening)
        let noQueens = try Position(fen: "rnb1kbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNB1KB1R b KQkq - 1 5")
        XCTAssertEqual(noQueens.phase(ply: 9), .middlegame)
    }

    func testEndgameByMaterial() throws {
        let p = try Position(fen: "4k3/5r2/8/3b4/8/2N5/5R2/4K3 w - - 0 40")
        XCTAssertEqual(p.minorsAndMajors, 4)
        XCTAssertEqual(p.phase(ply: 78), .endgame)
        XCTAssertEqual(try Position(fen: Position.startFEN).phase(ply: 0), .opening)
        // Monotone: an endgame stays an endgame.
        XCTAssertEqual(GamePhases.classify([p, .start], plies: [78, 79]), [.endgame, .endgame])
    }

    func testPhaseReport() {
        let moves = [
            ScoredMove(side: .white, phase: .opening, loss: 0, severity: 0),
            ScoredMove(side: .white, phase: .opening, loss: 0, severity: 0),
            ScoredMove(side: .white, phase: .middlegame, loss: 25, severity: 3),
            ScoredMove(side: .white, phase: .middlegame, loss: 0, severity: 0),
            ScoredMove(side: .black, phase: .opening, loss: 6, severity: 1),
        ]
        let r = PhaseReport.compute(moves)
        XCTAssertEqual(r[.white]?[.opening]?.moves, 2)
        XCTAssertEqual(r[.white]?[.opening]?.accuracy ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(r[.white]?[.middlegame]?.blunders, 1)
        XCTAssertLessThan(r[.white]?[.middlegame]?.accuracy ?? 100, 80)
        XCTAssertEqual(r[.black]?[.opening]?.inaccuracies, 1)
        XCTAssertNil(r[.black]?[.endgame])
        let x = try! XCTUnwrap(PhaseReport.extremes(r[.white]!))
        XCTAssertEqual(x.best, .opening); XCTAssertEqual(x.worst, .middlegame)
        XCTAssertNil(PhaseReport.extremes(r[.black]!))
    }
}

final class GroundingTests: XCTestCase {
    func testCitations() {
        let c = Grounding.citations(in: "After 23...Nf6 24. Qd2 Bxd2+ White castles O-O; the knight on f5 and exd5 matter, also 12…e5 and e8=Q.")
        XCTAssertEqual(c.map(\.san), ["Nf6", "Qd2", "Bxd2+", "O-O", "exd5", "e5", "e8=Q"])
        XCTAssertEqual(c[0].number, 23); XCTAssertTrue(c[0].black)
        XCTAssertEqual(c[1].number, 24); XCTAssertFalse(c[1].black)
        XCTAssertTrue(c[5].black)
        // Squares, words and scores are not moves.
        XCTAssertEqual(Grounding.citations(in: "The bishop on c4 eyes f7; Black is +1.5 up. Nothing else.").map(\.san), [])
        XCTAssertEqual(Grounding.citations(in: "0-0-0 and Raxd1#").map(\.san), ["0-0-0", "Raxd1#"])
    }

    func testUnsupportedAndPrune() {
        let allowed = Grounding.allowed(["e4", "e5", "Nf3", "Nc6", "Bb5", "O-O", "exd5"])
        XCTAssertEqual(Grounding.unsupported(in: "2. Nf3 and Bb5+ then 0-0, later Nxe5 and Qh5.", allowed: allowed), ["Nxe5", "Qh5"])
        XCTAssertEqual(Grounding.unsupported(in: "exd5 is fine (e x d5 written exd5).", allowed: allowed), [])
        let p = Grounding.prune("Develop first with 2. Nf3. Then Qh5 wins. Castle early.", allowed: allowed)
        XCTAssertEqual(p.text, "Develop first with 2. Nf3. Castle early.")
        XCTAssertEqual(p.dropped, ["Then Qh5 wins."])
    }

    func testClean() {
        let allowed = Grounding.allowed(["Nf3"])
        XCTAssertEqual(Grounding.clean("Play Nf3. Not Qh5.", allowed: allowed).text, "Play Nf3.")
        let all = Grounding.clean("Qh5 was the idea.", allowed: allowed)
        XCTAssertEqual(all.text, "Qh5 was the idea.")
        XCTAssertEqual(all.unverified, ["Qh5"])
        XCTAssertEqual(Grounding.clean("Develop pieces.", allowed: allowed).unverified, [])
    }

    func testPlyOfReference() {
        let line = ["e4", "e5", "Nf3", "Nc6", "Bb5", "Nf6"]
        XCTAssertEqual(Grounding.ply(of: "3...Nf6", line: line), 6)
        XCTAssertEqual(Grounding.ply(of: "3. Nf6", line: line), 6)          // wrong dots, same move number
        XCTAssertEqual(Grounding.ply(of: "Bb5", line: line), 5)
        XCTAssertEqual(Grounding.ply(of: "2\u{2026}Nc6", line: line), 4)
        XCTAssertEqual(Grounding.ply(of: "e5", line: line), 2)
        XCTAssertEqual(Grounding.ply(of: "4", line: line), 4)
        XCTAssertNil(Grounding.ply(of: "Qh5", line: line))
    }
}

final class AIResponseTests: XCTestCase {
    func testMomentLessonJSONWithFences() {
        let text = """
        Here you go:
        ```json
        {"concept": "Loose pieces", "idea": "Unprotected pieces {drop} off.", "what_went_wrong": "You thought it was safe.",
         "betterIdea": "Nf3 guards it.", "rule": "Check every piece is defended."}
        ```
        """
        let l = MomentLesson.parse(text)
        XCTAssertEqual(l?.concept, "Loose pieces")
        XCTAssertEqual(l?.idea, "Unprotected pieces {drop} off.")
        XCTAssertEqual(l?.whatWentWrong, "You thought it was safe.")
        XCTAssertEqual(l?.rule, "Check every piece is defended.")
        XCTAssertNil(l?.plain)
    }

    func testMomentLessonPlainFallback() {
        XCTAssertEqual(MomentLesson.parse("The knight was loose.")?.plain, "The knight was loose.")
        XCTAssertEqual(MomentLesson.parse("{not json} just text")?.plain, "{not json} just text")
        XCTAssertNil(MomentLesson.parse("   "))
    }

    func testGameLesson() {
        let text = """
        {"headline": "White won a sharp game.", "story": "Black's king stayed in the centre.",
         "concepts": [{"name": "King safety", "explanation": "Castle early.", "moves": ["9...Ke7"]}, "Loose pieces"],
         "white": "Strong attack.", "black": "Weak middlegame.", "turningPoint": 18,
         "lessons": ["Castle before move 10.", "Count attackers.", "Check loose pieces.", "Extra"],
         "exercises": [{"title": "Safe king", "fromMove": "9...Ke7", "task": "Find a safe king move.", "concept": "King safety"}, {"title": "no task"}]}
        """
        let g = GameLesson.parse(text)
        XCTAssertEqual(g?.headline, "White won a sharp game.")
        XCTAssertEqual(g?.concepts.count, 2)
        XCTAssertEqual(g?.concepts.first?.moves, ["9...Ke7"])
        XCTAssertEqual(g?.concepts.last?.name, "Loose pieces")
        XCTAssertEqual(g?.turningPoint, GameLesson.Example(move: "18"))
        XCTAssertNil(g?.concepts.first?.examples.first?.why)
        XCTAssertEqual(g?.lessons.count, 3)
        XCTAssertEqual(g?.exercises.count, 1)
        XCTAssertEqual(g?.exercises.first?.fromMove, "9...Ke7")
    }

    func testGameLessonExamples() {
        let text = """
        {"concepts": [{"name": "Rapid development", "explanation": "White developed fast.",
           "examples": [{"move": "11. Bxb5+", "why": "The bishop joins with check; Black's king is still in the centre.",
                         "arrows": ["b5e8", "B5-D7", "zz99", "b5b5", {"from": "d1", "to": "d8"}, "a1a8"], "squares": ["e8", "E8", "k9", "d7", "c6", "b7", "a7"]},
                        "6...Nf6", {"why": "no move"}]}],
         "turningPoint": {"move": "13. Rxd7", "why": "The rook sacrifice tears open the d-file.", "arrows": ["d1d8"]}}
        """
        let g = GameLesson.parse(text)
        let ex = g?.concepts.first?.examples ?? []
        XCTAssertEqual(ex.count, 2)
        XCTAssertEqual(ex[0].move, "11. Bxb5+")
        XCTAssertEqual(ex[0].why, "The bishop joins with check; Black's king is still in the centre.")
        // Invalid and same-square arrows dropped, at most 3 kept.
        XCTAssertEqual(ex[0].arrows.map(\.uci), ["b5e8", "b5d7", "d1d8"])
        // Invalid squares dropped, duplicates merged, at most 4 kept.
        XCTAssertEqual(ex[0].squares.map(Sq.name), ["e8", "d7", "c6", "b7"])
        XCTAssertEqual(ex[1], GameLesson.Example(move: "6...Nf6"))
        XCTAssertEqual(g?.concepts.first?.moves, ["11. Bxb5+", "6...Nf6"])
        XCTAssertEqual(g?.turningPoint?.move, "13. Rxd7")
        XCTAssertEqual(g?.turningPoint?.arrows.map(\.uci), ["d1d8"])
    }

    func testGameLessonLegacyMoveObjects() {
        // Older prompt key "moves" holding objects still reads.
        let g = GameLesson.parse(#"{"concepts": [{"name": "Pins", "explanation": "x", "moves": [{"move": "9. Bg5", "why": "Pins the knight."}]}]}"#)
        XCTAssertEqual(g?.concepts.first?.examples.first?.why, "Pins the knight.")
        XCTAssertEqual(GameLesson.Example.Arrow("e2 e4")?.uci, "e2e4")
        XCTAssertNil(GameLesson.Example.Arrow("e2e"))
    }

    func testGameLessonGrounded() {
        let game = PGN.parse("1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 1-0")[0].game
        let allowed = Grounding.allowed(game.mainlineSAN)
        let line = game.mainlineSAN
        let lesson = GameLesson(
            headline: "Morphy won. Then 30. Qh7 happened.",
            concepts: [GameLesson.Concept(name: "Development", explanation: "Fast.", examples: [
                GameLesson.Example(move: "11. Bxb5+", why: "Check with a developed piece. Not like 25. Qh7 at all."),
                GameLesson.Example(move: "40. Kh1", why: "Not in the game."),
                GameLesson.Example(move: "6...Nf6", why: "Only 25. Qh7 here."),
            ])],
            turningPoint: GameLesson.Example(move: "99. Ra1"))
        let (g, unverified) = lesson.grounded(allowed: allowed) { Grounding.ply(of: $0, line: line) != nil }
        let ex = g.concepts[0].examples
        XCTAssertEqual(ex.map(\.move), ["11. Bxb5+", "6...Nf6"])
        XCTAssertEqual(ex[0].why, "Check with a developed piece.")
        XCTAssertNil(ex[1].why)
        XCTAssertNil(g.turningPoint)
        XCTAssertEqual(g.headline, "Morphy won.")
        XCTAssertEqual(unverified, [])
    }

    func testGameLessonRawFallback() {
        let g = GameLesson.parse("The model forgot to use JSON.")
        XCTAssertEqual(g?.story, "The model forgot to use JSON.")
        XCTAssertNil(g?.headline)
    }
}

final class EngineToolTests: XCTestCase {
    func testParseRequests() {
        let r = EngineTool.requests(in: #"Let me check. <engine fen="rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1" moves="1...e5 2. Nf3"/>"#)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].moves, ["e5", "Nf3"])
        XCTAssertTrue(r[0].fen.hasPrefix("rnbqkbnr/pppppppp/8/8/4P3"))
        XCTAssertEqual(EngineTool.requests(in: "<engine fen='8/8/8/8/8/8/8/K1k5 w - - 0 1'>").first?.moves, [])
        XCTAssertEqual(EngineTool.requests(in: #"{"concept": "x"}"#), [])
        XCTAssertTrue(EngineTool.hasCompleteRequest(#"<engine fen="x"/>"#))
        XCTAssertFalse(EngineTool.hasCompleteRequest(#"<engine fen="x"#))
        XCTAssertEqual(EngineToolRequest(fen: "F", moves: ["e4"]).tag, #"<engine fen="F" moves="e4"/>"#)
    }

    func testResolve() throws {
        let ok = EngineTool.resolve(EngineToolRequest(fen: Position.startFEN, moves: ["e4", "e5", "Nf3"]))
        guard case .success(let r) = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(r.sans, ["e4", "e5", "Nf3"])
        XCTAssertEqual(r.position.turn, .black)
        guard case .failure(.badFEN("garbage")) = EngineTool.resolve(EngineToolRequest(fen: "garbage")) else { return XCTFail("bad FEN accepted") }
        guard case .failure(.illegal(let m, _)) = EngineTool.resolve(EngineToolRequest(fen: Position.startFEN, moves: ["e4", "Ke2"]))
        else { return XCTFail("expected illegal") }
        XCTAssertEqual(m, "Ke2")
        XCTAssertTrue(EngineTool.Failure.badFEN("x").message.contains("not a valid FEN"))
    }

    func testResultText() throws {
        let start = Position.start
        let after = try start.applying(start.parseSAN("e4"))
        let lines = [EngineToolLine(eval: .cp(-30), pv: ["e7e5", "g1f3"]), EngineToolLine(eval: .mate(-2), pv: ["c7c5"])]
        let r = EngineTool.result(for: EngineToolRequest(fen: start.fen, moves: ["e4"]), start: start, sans: ["e4"],
                                  position: after, lines: lines, depth: 18)
        XCTAssertTrue(r.text.contains("depth 18 after 1. e4. Black to move."))
        XCTAssertTrue(r.text.contains("1) +0.30 for Black, the side to move (White's view: -0.30): 1\u{2026} e5 2. Nf3"))
        XCTAssertTrue(r.text.contains("2) mates in 2 for Black"))
        XCTAssertEqual(r.sans, ["e4", "e5", "Nf3", "c5"])
    }

    func testTranscript() {
        let t = EngineTool.transcript(prompt: "P", turns: [.init(request: "<engine fen=\"F\"/>", reply: "R")], callsLeft: 0, note: "N")
        XCTAssertTrue(t.hasPrefix("P\n\n--- Engine results so far ---\nYou asked: <engine fen=\"F\"/>\nR"))
        XCTAssertTrue(t.contains("No engine calls left"))
        XCTAssertTrue(t.hasSuffix("\n\nN"))
        XCTAssertEqual(EngineTool.transcript(prompt: "P", turns: [], callsLeft: 4), "P")
    }
}

final class SummaryPromptTests: XCTestCase {
    func facts() -> SummaryFacts {
        let g = PGN.parse("""
        [White "Alice"]
        [Black "Bob"]
        [WhiteElo "1500"]
        [Result "1-0"]
        [Opening "Ruy Lopez"]
        [ECO "C60"]

        1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0
        """)[0].game
        var f = SummaryFacts(moves: g.mainlineSAN, evals: [.cp(30), .cp(25), .cp(40), .cp(35), .mate(5)],
                             accuracy: [.white: 91.6, .black: 70.2],
                             phases: [.black: [.opening: { var s = PhaseStat(); s.moves = 2; s.accuracy = 70; s.blunders = 1; return s }()]],
                             moments: [SummaryMoment(ply: 4, label: "2\u{2026}Nc6", side: .black, classification: "blunder",
                                                     phase: .opening, evalBefore: .cp(25), evalAfter: .cp(400), tags: ["allows a fork"],
                                                     fenBefore: "FENX", refutation: "3. Bb5", best: "2\u{2026} d6")])
        f.setHeaders(from: g)
        return f
    }

    func testFullPrompt() {
        let p = SummaryPrompt.user(facts())
        XCTAssertTrue(p.contains("White: Alice (1500). Black: Bob."))
        XCTAssertTrue(p.contains("Result: 1-0. Opening: Ruy Lopez (C60)."))
        XCTAssertTrue(p.contains("Moves: 1. e4 e5 2. Nf3 Nc6 3. Bb5"))
        XCTAssertTrue(p.contains("1. +0.3 +0.2 2. +0.4 +0.3 3. M5"))
        XCTAssertTrue(p.contains("White: 92% accuracy"))
        XCTAssertTrue(p.contains("Black: 70% accuracy; opening 70% (2 moves, 1 blunder)"))
        XCTAssertTrue(p.contains("- 2\u{2026}Nc6 by Black, blunder in the opening; eval +0.2 to +4.0; allows a fork. FEN before: FENX. Engine reply: 3. Bb5. Better was: 2\u{2026} d6."))
    }

    func testCompactPrompt() {
        let p = SummaryPrompt.user(facts(), compact: true)
        XCTAssertTrue(p.contains("1. +0.2 2. +0.3 3. M5"))
        XCTAssertFalse(p.contains("FEN before"))
        XCTAssertLessThan(p.count, SummaryPrompt.user(facts()).count)
    }

    func testSystemPrompts() {
        XCTAssertTrue(SummaryPrompt.system(tool: true).contains("<engine fen="))
        XCTAssertFalse(SummaryPrompt.system(tool: false).contains("<engine"))
        let sys = SummaryPrompt.system(tool: false)
        for key in [#""examples""#, #""why""#, #""arrows""#, #""squares""#] { XCTAssertTrue(sys.contains(key), key) }
        XCTAssertFalse(sys.contains(#""moves": ["#))
        XCTAssertTrue(CoachPrompt.system(tool: false).contains("\"concept\""))
    }
}

final class MomentPickerTests: XCTestCase {
    static let opera = "1. e4 e5 2. Nf3 d6 3. d4 Bg4 4. dxe5 Bxf3 5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7 12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0"

    func node(_ g: Game, ply: Int) -> GameNode { g.nodes[g.mainline()[ply]] }

    func testMorphySacrifices() throws {
        let g = PGN.parse(Self.opera)[0].game
        func sac(_ ply: Int, _ reply: [String]) throws -> Int {
            let n = node(g, ply: ply)
            return g.nodes[n.parent!].position.sacrifice(played: try XCTUnwrap(n.move), reply: reply)
        }
        XCTAssertEqual(node(g, ply: 19).san, "Nxb5")
        XCTAssertEqual(try sac(19, ["c6b5", "c4b5", "b8d7"]), 2)          // knight for two pawns
        XCTAssertEqual(node(g, ply: 25).san, "Rxd7")
        XCTAssertEqual(try sac(25, ["d8d7", "h1d1", "e7e6"]), 2)          // the exchange
        XCTAssertEqual(node(g, ply: 31).san, "Qb8+")
        XCTAssertEqual(try sac(31, ["d7b8", "d1d8"]), 9)                  // the queen
        XCTAssertEqual(try sac(29, ["f6d7", "b3b8"]), 0)                  // 15. Bxd7+ wins material
        XCTAssertEqual(try sac(19, []), 0)                                // no line, no verdict
    }

    func testExchangeWonBackIsNoSacrifice() throws {
        let p = try Position(fen: "4k3/8/5n2/8/4P3/2N5/8/4K3 w - - 0 1")
        XCTAssertEqual(p.sacrifice(played: Move(uci: "c3d5")!, reply: ["f6d5", "e4d5"]), 0)
    }

    func testBands() {
        XCTAssertEqual(MomentPicker.band(.cp(50)), 0)
        XCTAssertEqual(MomentPicker.band(.cp(80)), 1)
        XCTAssertEqual(MomentPicker.band(.cp(-250)), -2)
        XCTAssertEqual(MomentPicker.band(.mate(-3)), -2)
    }

    func testPickOrderMergeAndBothSides() {
        let plies = [
            PlyReview(index: 1, mover: .white, evalBefore: .cp(20), evalAfter: .cp(30), loss: 0, severity: 0),
            // Black's inaccuracy, then a band change on the next ply: merged into the inaccuracy.
            PlyReview(index: 2, mover: .black, evalBefore: .cp(30), evalAfter: .cp(90), loss: 6, severity: 1),
            PlyReview(index: 3, mover: .white, evalBefore: .cp(90), evalAfter: .cp(210), loss: 0, severity: 0),
            // White already winning: +7 to +5.6 barely moves win% and stays above the swing ceiling.
            PlyReview(index: 4, mover: .black, evalBefore: .cp(700), evalAfter: .cp(560), loss: 1, severity: 0),
            // A swing of 1.2 pawns inside the winning band.
            PlyReview(index: 5, mover: .white, evalBefore: .cp(560), evalAfter: .cp(440), loss: 2, severity: 0),
            PlyReview(index: 7, mover: .white, evalBefore: .cp(400), evalAfter: .cp(420), loss: 0, severity: 0, positive: 1),
            PlyReview(index: 9, mover: .white, evalBefore: .cp(500), evalAfter: .mate(2), loss: 0, severity: 0, positive: 2),
            PlyReview(index: 12, mover: .black, evalBefore: .cp(-10), evalAfter: .cp(300), loss: 30, severity: 3),
        ]
        let p = MomentPicker.pick(plies)
        XCTAssertEqual(p.map(\.index), [2, 5, 7, 9, 12])
        XCTAssertEqual(p.map(\.kind), [.error(1), .turningPoint, .great, .brilliant, .error(3)])
        XCTAssertEqual(MomentPicker.pick(plies, limit: 2).map(\.index), [9, 12])
    }
}
