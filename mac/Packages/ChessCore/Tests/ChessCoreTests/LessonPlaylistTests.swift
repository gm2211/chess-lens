import XCTest
@testable import ChessCore

final class LessonPlaylistTests: XCTestCase {
    var sans: [String] { PGN.parse(MomentPickerTests.opera)[0].game.mainlineSAN }
    var line: LessonLine { LessonLine(start: .start, sans: sans) }

    func step(_ at: String, _ say: String) -> GameLesson.StoryStep { .init(at: at, say: say) }

    func lesson() -> GameLesson {
        GameLesson(headline: "Develop, then strike", story: "White developed fast. Black lagged behind.",
                   concepts: [
                    .init(name: "king safety", explanation: "", examples: [], story: [step("9. Bg5", "A"), step("12. O-O-O", "B")]),
                    .init(name: "development", explanation: "", examples: [], story: [step("2...d6", "C"), step("12. O-O-O", "D")]),
                   ],
                   turningPoint: .init(move: "11. Bxb5+", why: "The game turns."),
                   lessons: ["Develop pieces", "Castle early"])
    }

    func testOrderTiesIntroOutro() {
        let l = LessonPlaylist.build(lesson: lesson(), line: line)
        XCTAssertEqual(l.map(\.step.say).first, "Develop, then strike. White developed fast.")
        XCTAssertEqual(l.first?.concept, LessonPlaylist.introTitle)
        XCTAssertEqual(l.first?.ply, 0)
        let mid = l.dropFirst().dropLast()
        XCTAssertEqual(mid.map(\.step.say), ["C", "A", "The game turns.", "B", "D"])   // B before D: concept order on the tie
        XCTAssertEqual(mid.map(\.concept), ["Development", "King safety", "Turning point", "King safety", "Development"])
        XCTAssertEqual(mid.map(\.ply), mid.map(\.ply).sorted())
        XCTAssertEqual(l.last?.concept, LessonPlaylist.outroTitle)
        XCTAssertEqual(l.last?.step.say, "Habits to build. Develop pieces. Castle early.")
        XCTAssertEqual(l.last?.ply, sans.count)
    }

    func testTurningPointNotDuplicatedAndIdenticalDeduped() {
        var g = lesson()
        g.turningPoint = .init(move: "9. Bg5", why: "x")                   // already covered by a step
        g.concepts[1].story.append(step("9. Bg5", "A"))                     // identical to a king-safety step
        let mid = LessonPlaylist.build(lesson: g, line: line).dropFirst().dropLast()
        XCTAssertEqual(mid.map(\.step.say), ["C", "A", "B", "D"])
    }

    func testEmptyLessonAndUngroundedSteps() {
        XCTAssertTrue(LessonPlaylist.build(lesson: GameLesson(), line: line).isEmpty)
        var g = GameLesson(headline: "H", concepts: [.init(name: "x", explanation: "", examples: [], story: [step("99. Qh7", "nope")])])
        let l = LessonPlaylist.build(lesson: g, line: line)
        XCTAssertEqual(l.count, 1)                                          // intro only; no habits, bad step dropped
        g.lessons = ["Z"]
        XCTAssertEqual(LessonPlaylist.build(lesson: g, line: line).count, 2)
    }

    func testConceptsFollowTheGame() {
        let raw = GameLesson(concepts: [
            .init(name: "Mate", explanation: "", examples: [.init(move: "16. Qb8+"), .init(move: "17. Rd8#")]),
            .init(name: "Safety", explanation: "", examples: [.init(move: "9. Bg5")]),
            .init(name: "Development", explanation: "", examples: [.init(move: "2...d6")]),
            .init(name: "Nothing", explanation: ""),
        ])
        let (g, _) = raw.grounded(allowed: Grounding.allowed(sans), line: line)
        XCTAssertEqual(g.concepts.map(\.name), ["Development", "Safety", "Mate", "Nothing"])
    }
}

final class PieceMotionTests: XCTestCase {
    func moves(_ ucis: [String], from pos: Position = .start) -> [Move] {
        var p = pos; var out: [Move] = []
        for u in ucis { let m = p.move(fromUCI: u)!; out.append(m); p = try! p.applying(m) }
        return out
    }

    func testSimpleSlideAndCapture() {
        let ms = moves(["e2e4", "d7d5", "e4d5"])
        let s = PieceMotion.slides(board: Position.start.board, moves: ms)
        let pawn = s.first { $0.id == Sq.parse("e2")! }!
        XCTAssertEqual(pawn.to, Sq.parse("d5")!)
        XCTAssertEqual(s.first { $0.id == Sq.parse("d7")! }?.to, nil)       // captured
        XCTAssertEqual(s.count, 2)
    }

    func testCastlingMovesRookAndPromotion() throws {
        let castle = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        let s = PieceMotion.slides(board: castle.board, moves: moves(["e1g1"], from: castle))
        XCTAssertEqual(s.first { $0.id == Sq.parse("h1")! }?.to, Sq.parse("f1")!)
        XCTAssertEqual(s.first { $0.id == Sq.parse("e1")! }?.to, Sq.parse("g1")!)
        let promo = try Position(fen: "8/P6k/8/8/8/8/8/K7 w - - 0 1")
        let p = PieceMotion.slides(board: promo.board, moves: moves(["a7a8q"], from: promo))
        XCTAssertTrue(p[0].isPromotion)
        XCTAssertEqual(p[0].finalPiece, Piece(.white, .queen))
    }

    func testEnPassant() throws {
        let pos = try Position(fen: "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
        let s = PieceMotion.slides(board: pos.board, moves: moves(["e5d6"], from: pos))
        XCTAssertNil(s.first { $0.id == Sq.parse("d5")! }!.to)
    }

    func testHops() {
        let parents = [0: nil, 1: 0, 2: 1, 3: 2, 4: 3, 5: 4, 6: 5, 7: 6, 8: 7, 9: 6]
        let parent: (Int) -> Int? = { parents[$0] ?? nil }
        XCTAssertEqual(PieceMotion.hops(from: 1, to: 3, parent: parent), [2, 3])
        XCTAssertEqual(PieceMotion.hops(from: 3, to: 1, parent: parent), [2, 1])
        XCTAssertEqual(PieceMotion.hops(from: 0, to: 6, parent: parent), [1, 2, 3, 4, 5, 6]) // 6 hops: all walked
        XCTAssertEqual(PieceMotion.hops(from: 0, to: 7, parent: parent), [3, 4, 5, 6, 7])     // 7 hops: jump to 3, then last 4
        XCTAssertEqual(PieceMotion.hops(from: 8, to: 9, parent: parent), [9])                 // unrelated: jump
        XCTAssertEqual(PieceMotion.hops(from: 4, to: 4, parent: parent), [])
    }
}
