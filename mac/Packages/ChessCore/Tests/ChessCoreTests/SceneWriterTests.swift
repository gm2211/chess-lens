import XCTest
@testable import ChessCore

final class SceneWriterTests: XCTestCase {
    typealias Step = GameLesson.SceneStep

    var line: LessonLine { LessonLine(start: .start, sans: PGN.parse(MomentPickerTests.opera)[0].game.mainlineSAN) }

    /// The Opera game before 6...Nf6: Black to move; 7. Qb3 then hits b7 and f7 (the bishop and queen against f7).
    var operaMoment: SceneWriter.Moment {
        SceneWriter.Moment(root: line.position(atPly: 11)!, played: "g8f6", refutation: ["f3b3", "d8e7", "b1c3", "c7c6"],
                           best: "d8f6", classification: "inaccuracy")
    }

    func pos(_ fen: String) -> Position { try! Position(fen: fen) }

    // MARK: Features

    func testQueenDoubleAttack() {
        let after = line.position(atPly: 12)!                       // after 6...Nf6
        let qb3 = after.move(fromUCI: "f3b3")!
        let f = after.features(qb3)
        XCTAssertEqual(Set(f.hanging), [Sq.parse("b7")!, Sq.parse("f7")!])
        XCTAssertFalse(f.check)
        XCTAssertEqual(after.spoken(qb3), "queen b3")
        XCTAssertEqual(SceneWriter.threatClause(qb3, from: after), "hits b7 and f7")
    }

    func testSpokenMoves() {
        let p = pos("r3k2r/8/8/3p4/4P3/8/8/R3K2R w KQkq - 0 1")
        XCTAssertEqual(p.spoken(p.move(fromUCI: "e4d5")!), "e takes d5")
        XCTAssertEqual(p.spoken(p.move(fromUCI: "e1c1")!), "castles long")
        XCTAssertEqual(p.spoken(p.move(fromUCI: "e1g1")!), "castles")
        XCTAssertEqual(p.spoken(p.move(fromUCI: "a1a8")!), "rook takes a8, check")
    }

    func testBatteryCountsAsAttackers() {
        let after = try! line.position(atPly: 12)!.applying(Move(uci: "f3b3")!)
        XCTAssertEqual(after.attackerCount(Sq.parse("f7")!, by: .white), 2)    // Bc4 with Qb3 behind it
        XCTAssertEqual(after.attackerCount(Sq.parse("f7")!, by: .black), 1)    // the king
        XCTAssertTrue(after.isHanging(Sq.parse("f7")!))
    }

    // MARK: Error scenes

    func testErrorSceneFollowsTheVideoOrder() {
        let beat = GameLesson.Beat(kind: .slip, at: "6...Nf6", headline: "Black's 6...Nf6 is an inaccuracy.", rule: "Watch f7.", ply: 12)
        let s = SceneWriter.scene(beat: beat, moment: operaMoment)
        XCTAssertTrue((6...12).contains(s.count), "\(s.count) steps")
        XCTAssertTrue(s[0].moves.isEmpty && !s[0].ask)                       // the stakes
        XCTAssertTrue(s[1].ask && s[1].moves.isEmpty)                        // what would you play?
        XCTAssertEqual(s[2].moves, ["g8f6"])                                 // the tempting move
        XCTAssertTrue(s[2].say.contains("knight f6"))
        XCTAssertEqual(s[3].moves, ["f3b3"])                                 // but wait
        XCTAssertTrue(s[3].say.contains("Queen b3"))
        XCTAssertTrue(s[3].say.contains("b7 and f7 are both hanging"), s[3].say)
        XCTAssertEqual(Set(s[3].circles), [Sq.parse("b7")!, Sq.parse("f7")!])
        let instead = s.firstIndex { $0.rewind == .root }!
        XCTAssertEqual(s[instead].moves, ["d8f6"])
        XCTAssertTrue(s[instead].say.contains("queen f6"))
        XCTAssertTrue(s[instead + 1].say.contains("f7"), s[instead + 1].say)  // covers f7
        XCTAssertEqual(s.last?.rewind, .game)
        XCTAssertTrue(s.last!.say.contains("Watch f7."))
        // Legal throughout, no numbers spoken.
        XCTAssertEqual(BeatScene.validated(s, root: operaMoment.root, game: line.position(atPly: 12)!), s)
        XCTAssertFalse(s.contains { $0.say.contains("+") || $0.say.contains("%") })
        XCTAssertEqual(s, SceneWriter.scene(beat: beat, moment: operaMoment))   // deterministic
    }

    func testCaptureSequenceBundlesTheRecapture() {
        // Black's ...h6 lets Bxf6 gxf6 Qxf6 win a pawn.
        let root = pos("6k1/5ppp/5n2/6B1/3Q4/8/8/6K1 b - - 0 1")
        let m = SceneWriter.Moment(root: root, played: "h7h6", refutation: ["g5f6", "g7f6", "d4f6", "g8h7"], best: "g8h8",
                                   classification: "mistake")
        let s = SceneWriter.scene(beat: GameLesson.Beat(kind: .slip, at: "x", headline: "h", ply: 1), moment: m)
        let line = s.filter { !$0.moves.isEmpty && $0.rewind == nil }.dropFirst()   // after the game move
        XCTAssertEqual(line.map(\.moves), [["g5f6"], ["g7f6", "d4f6"]])
        let last = line.last!.say
        XCTAssertTrue(last.lowercased().contains("g takes f6, queen takes f6"), last)
        XCTAssertTrue(last.contains("White wins a pawn."), last)
        XCTAssertEqual(line.last?.pause, 1.0)
    }

    func testMateIsThePunchline() {
        // Black's rook leaves the back rank: Re8 is mate.
        let root = pos("r5k1/5ppp/8/8/8/8/5PPP/4R1K1 b - - 0 1")
        let m = SceneWriter.Moment(root: root, played: "a8a2", refutation: ["e1e8", "g8h7"], best: "h7h6", classification: "blunder")
        let s = SceneWriter.scene(beat: GameLesson.Beat(kind: .turning, at: "x", headline: "h", ply: 1), moment: m)
        let mate = s.first { $0.moves == ["e1e8"] }!
        XCTAssertTrue(mate.say.contains("Rook e8, checkmate."), mate.say)
        XCTAssertTrue(mate.say.contains("Game over."), mate.say)
        XCTAssertTrue(s[0].say.contains("decides the game"))
        let after = try! root.applying(Move(uci: "a8a2")!)
        XCTAssertEqual(SceneWriter.threatClause(Move(uci: "e1e8")!, from: after), "is checkmate")
    }

    func testInfoSceneIsShort() {
        let beat = GameLesson.Beat(kind: .setup, at: "start", headline: "Both sides develop.",
                                   explain: "White grabs the centre. Black copies. Then the bishops come out.",
                                   circles: [Sq.parse("e4")!], ply: 0)
        let s = SceneWriter.scene(beat: beat, moment: nil)
        XCTAssertTrue((2...4).contains(s.count))
        XCTAssertEqual(s[0].say, "Both sides develop.")
        XCTAssertEqual(s[0].circles, [Sq.parse("e4")!])
        XCTAssertTrue(s.allSatisfy { $0.moves.isEmpty && !$0.ask && $0.rewind == nil })
    }

    func testPunishBeatPointsAtTheThreat() {
        let beat = GameLesson.Beat(kind: .punish, at: "7. Qb3", headline: "White punishes it.", ply: 13)
        let before = line.position(atPly: 12)!
        let s = SceneWriter.scene(beat: beat, moment: nil, lastMove: Move(uci: "f3b3"), before: before)
        XCTAssertTrue(s[1].say.hasPrefix("Look at queen b3."), s[1].say)
        XCTAssertTrue(s[1].say.contains("both hanging"))
    }

    // MARK: Scripts

    func testParseScript() {
        let json = """
        {"beats": [{"kind": "slip", "at": "6...Nf6", "headline": "Natural, but wrong.", "script": [
          {"say": "Black to move. What would you play?", "ask": true},
          {"say": "Knight f6. Developing!", "play": ["Nf6"]},
          {"say": "But wait. Queen b3.", "moves": "7. Qb3", "arrows": ["b3b7"], "circles": ["b7", "f7"]},
          {"say": "So instead, queen f6.", "moves": ["d8f6"], "rewind": "question"},
          {"say": "And in the game...", "rewind": "game", "pause": "1"},
          {"arrows": ["a1a2"]}
        ]}]}
        """
        let b = GameLesson.parse(json)!.beats[0]
        XCTAssertEqual(b.script.count, 5)                                      // the last says and does nothing
        XCTAssertTrue(b.script[0].ask)
        XCTAssertEqual(b.script[2].moves, ["Qb3"])
        XCTAssertEqual(b.script[2].circles.count, 2)
        XCTAssertEqual(b.script[3].rewind, .root)
        XCTAssertEqual(b.script[4].rewind, .game)
        XCTAssertEqual(b.script[4].pause, 1)
    }

    func testValidationConvertsAndCuts() {
        let root = line.position(atPly: 11)!, game = line.position(atPly: 12)!
        let steps = [Step(say: "Ask.", ask: true), Step(say: "Played.", moves: ["Nf6"]), Step(say: "Qb3!", moves: ["Qb3"]),
                     Step(say: "Nonsense.", moves: ["Qh8"]), Step(say: "More.", moves: ["e4"]),
                     Step(say: "Back.", rewind: .game), Step(say: "Then.", moves: ["Qb3"])]
        let v = BeatScene.validated(steps, root: root, game: game)
        XCTAssertEqual(v.map(\.say), ["Ask.", "Played.", "Qb3!", "Back.", "Then."])
        XCTAssertEqual(v[1].moves, ["g8f6"])
        XCTAssertEqual(v[2].moves, ["f3b3"])
        XCTAssertEqual(v[4].moves, ["f3b3"])                                   // replayed from the game position
        XCTAssertEqual(BeatScene.validated(v, root: root, game: game), v)       // idempotent
        let after = BeatScene.position(after: 2, of: v, root: root, game: game)
        XCTAssertEqual(after.board[Sq.parse("b3")!], Piece(.white, .queen))
    }

    func testGroundingKeepsScriptMovesAndSpokenMoves() {
        let root = line.position(atPly: 11)!, game = line.position(atPly: 12)!
        let steps = [Step(say: "Knight f6, natural. Nf6 develops.", moves: ["Nf6"]),
                     Step(say: "Qb3 hits b7. Qh5 would be silly.", moves: ["Qb3"]),
                     Step(say: "Qh5 again.", moves: ["Qe7"]),
                     Step(say: "Qh5 once more.")]
        let g = BeatScene.grounded(steps, allowed: [], root: root, game: game)
        XCTAssertEqual(g.map(\.say), ["Knight f6, natural. Nf6 develops.", "Qb3 hits b7.", "Queen e7."])
    }

    func testGroundedBeatsReplayScriptFromTheQuestion() {
        let script = [Step(say: "What would you play?", ask: true), Step(say: "Knight f6.", moves: ["Nf6"]),
                      Step(say: "Queen b3!", moves: ["Qb3"])]
        let slip = GameLesson.Beat(kind: .slip, at: "6...Nf6", headline: "Oops.", script: script)
        let punish = GameLesson.Beat(kind: .punish, at: "7. Qb3", headline: "Ouch.", script: [Step(say: "Queen e7.", moves: ["Qe7"])])
        let g = GameLesson.groundedBeats([slip, punish], allowed: Grounding.allowed(line.sans), line: line)
        XCTAssertEqual(g[0].script.map(\.moves), [[], ["g8f6"], ["f3b3"]])
        XCTAssertEqual(g[1].script.map(\.moves), [["d8e7"]])                  // after its own move
    }

    func testEnsuringAskGoesBeforeTheFirstMove() {
        let steps = [Step(say: "Stakes."), Step(say: "Played.", moves: ["g8f6"]), Step(say: "Back.", rewind: .game)]
        XCTAssertEqual(BeatScene.ensuringAsk(steps).map(\.ask), [false, true, false, false])
        let asked = [Step(say: "Ask?", ask: true)] + steps
        XCTAssertEqual(BeatScene.ensuringAsk(asked), asked)
    }

    func testPromptAsksForScripts() {
        let p = SummaryPrompt.system(tool: false)
        XCTAssertTrue(p.contains(#""script": [{"say""#))
        XCTAssertTrue(p.contains("GothamChess"))
        XCTAssertTrue(p.contains("under 1200 words"))
    }
}
