import XCTest
@testable import ChessCore

final class PerftTests: XCTestCase {
    func perft(_ fen: String, _ depth: Int) throws -> Int { try Position(fen: fen).perft(depth) }

    func testStartPosition() throws {
        XCTAssertEqual(Position.start.perft(1), 20)
        XCTAssertEqual(Position.start.perft(2), 400)
        XCTAssertEqual(Position.start.perft(3), 8902)
        XCTAssertEqual(Position.start.perft(4), 197281)
    }

    func testKiwipete() throws {
        let f = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        XCTAssertEqual(try perft(f, 1), 48)
        XCTAssertEqual(try perft(f, 2), 2039)
        XCTAssertEqual(try perft(f, 3), 97862)
    }

    func testEnPassantEndgame() throws {
        let f = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1"
        XCTAssertEqual(try perft(f, 3), 2812)
        XCTAssertEqual(try perft(f, 4), 43238)
    }

    func testCastlingAndPromotionPosition() throws {
        let f = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1"
        XCTAssertEqual(try perft(f, 1), 6)
        XCTAssertEqual(try perft(f, 2), 264)
        XCTAssertEqual(try perft(f, 3), 9467)
    }

    func testPromotionHeavy() throws {
        let f = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8"
        XCTAssertEqual(try perft(f, 1), 44)
        XCTAssertEqual(try perft(f, 2), 1486)
        XCTAssertEqual(try perft(f, 3), 62379)
    }

    func testPosition6() throws {
        let f = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10"
        XCTAssertEqual(try perft(f, 2), 2079)
    }
}

final class FENAndSANTests: XCTestCase {
    func testFENRoundTrip() throws {
        let f = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
        XCTAssertEqual(try Position(fen: f).fen, f)
        XCTAssertEqual(Position.start.fen, Position.startFEN)
    }

    func testInvalidFEN() {
        XCTAssertThrowsError(try Position(fen: "8/8/8/8/8/8/8 w - - 0 1"))
        XCTAssertThrowsError(try Position(fen: "8/8/8/8/8/8/8/8 w - - 0 1"))   // no kings
        XCTAssertThrowsError(try Position(fen: "rnbqkbnr/pppppppp/9/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"))
    }

    func testSANFormatting() throws {
        var p = Position.start
        for (san, expected) in [("e4", "e4"), ("e5", "e5"), ("Nf3", "Nf3"), ("Nc6", "Nc6"), ("Bb5", "Bb5")] {
            let m = try p.parseSAN(san)
            XCTAssertEqual(p.san(m), expected)
            p = try p.applying(m)
        }
        XCTAssertEqual(p.fen, "r1bqkbnr/pppp1ppp/2n5/1B2p3/4P3/5N2/PPPP1PPP/RNBQK2R b KQkq - 3 3")
    }

    func testDisambiguation() throws {
        let p = try Position(fen: "4k3/8/8/8/8/8/4K3/R6R w - - 0 1")
        XCTAssertEqual(p.san(try p.parseSAN("Rad1")), "Rad1")
        XCTAssertEqual(p.san(try p.parseSAN("Rhf1")), "Rhf1")
        let q = try Position(fen: "4k3/8/8/8/R7/8/8/R3K3 w - - 0 1")
        XCTAssertEqual(q.san(try q.parseSAN("R1a2")), "R1a2")
        XCTAssertEqual(q.san(try q.parseSAN("R4a2")), "R4a2")
    }

    func testCastlingSAN() throws {
        let p = try Position(fen: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
        let k = try p.parseSAN("O-O")
        XCTAssertEqual(k, Move(from: 4, to: 6))
        XCTAssertEqual(p.san(k), "O-O")
        XCTAssertEqual(try p.parseSAN("0-0-0"), Move(from: 4, to: 2))
        let after = try p.applying(k)
        XCTAssertEqual(after.placementFEN, "r3k2r/8/8/8/8/8/8/R4RK1")
        XCTAssertFalse(after.castling.contains(.whiteKingside))
        XCTAssertTrue(after.castling.contains(.blackKingside))
    }

    func testCannotCastleThroughCheck() throws {
        let p = try Position(fen: "4k3/8/8/8/8/8/5r2/R3K2R w KQ - 0 1")
        XCTAssertFalse(p.legalMoves().contains(Move(from: 4, to: 6)))
        XCTAssertTrue(p.legalMoves().contains(Move(from: 4, to: 2)))
    }

    func testEnPassant() throws {
        var p = try Position(fen: "rnbqkbnr/ppp1pppp/8/8/3pP3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 3")
        let m = try p.parseSAN("dxe3")
        XCTAssertEqual(p.san(m), "dxe3")
        p = try p.applying(m)
        XCTAssertNil(p.board[Sq.parse("e4")!])
        XCTAssertEqual(p.piece(at: Sq.parse("e3")!), Piece(.black, .pawn))
    }

    func testPromotionSAN() throws {
        let p = try Position(fen: "8/P6k/8/8/8/8/7K/8 w - - 0 1")
        let m = try p.parseSAN("a8=Q")
        XCTAssertEqual(m.promotion, .queen)
        XCTAssertEqual(p.san(m), "a8=Q")
        XCTAssertEqual(try p.parseSAN("a8N"), Move(from: 48, to: 56, promotion: .knight))
        XCTAssertEqual(try p.parseSAN("a7a8r"), Move(from: 48, to: 56, promotion: .rook))
        XCTAssertEqual(Move(uci: "a7a8q")?.promotion, .queen)
    }

    func testCheckAndMateSuffix() throws {
        var p = Position.start
        for s in ["f3", "e5", "g4"] { p = try p.applying(try p.parseSAN(s)) }
        let m = try p.parseSAN("Qh4#")
        XCTAssertEqual(p.san(m), "Qh4#")
        p = try p.applying(m)
        XCTAssertTrue(p.isCheckmate)
        XCTAssertThrowsError(try Position.start.parseSAN("Nf6"))
    }

    func testStalemateAndInsufficient() throws {
        XCTAssertTrue(try Position(fen: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1").isStalemate)
        XCTAssertTrue(try Position(fen: "8/8/4k3/8/8/3K4/8/6N1 w - - 0 1").isInsufficientMaterial)
        XCTAssertFalse(Position.start.isInsufficientMaterial)
    }
}

final class PGNTests: XCTestCase {
    static let opera = """
    [Event "Opera Game"]
    [Site "Paris FRA"]
    [Date "1858.??.??"]
    [Round "?"]
    [White "Paul Morphy"]
    [Black "Duke Karl / Count Isouard"]
    [Result "1-0"]

    1. e4 e5 2. Nf3 d6 3. d4 Bg4 {This is a weak move already.--Fischer} 4. dxe5 Bxf3
    5. Qxf3 dxe5 6. Bc4 Nf6 7. Qb3 Qe7 8. Nc3 c6 9. Bg5 b5 10. Nxb5 cxb5 11. Bxb5+ Nbd7
    12. O-O-O Rd8 13. Rxd7 Rxd7 14. Rd1 Qe6 15. Bxd7+ Nxd7 16. Qb8+ Nxb8 17. Rd8# 1-0
    """

    func testParseOperaGame() throws {
        let games = PGN.parse(Self.opera)
        XCTAssertEqual(games.count, 1)
        let g = games[0].game
        XCTAssertNil(games[0].issue)
        XCTAssertEqual(g.mainlineSAN.count, 33)
        XCTAssertEqual(g.mainlineSAN.last, "Rd8#")
        XCTAssertEqual(g.header("White"), "Paul Morphy")
        XCTAssertEqual(g.result, "1-0")
        XCTAssertTrue(g.nodes[g.mainline().last!].position.isCheckmate)
        XCTAssertEqual(g.nodes.first(where: { $0.comment != nil })?.comment, "This is a weak move already.--Fischer")
    }

    func testVariationsAndNAGs() throws {
        let text = """
        [White "A"] [Black "B"]
        1. e4 e5 (1... c5 2. Nf3 (2. Nc3 Nc6) 2... d6) 2. Nf3 $1 Nc6! {develop} 3. Bb5 a6?! 1/2-1/2
        """
        let pg = PGN.parse(text)[0]
        XCTAssertNil(pg.issue)
        let g = pg.game
        XCTAssertEqual(g.mainlineSAN, ["e4", "e5", "Nf3", "Nc6", "Bb5", "a6"])
        let e4 = g.nodes[0].children[0]
        XCTAssertEqual(g.nodes[e4].children.count, 2)
        let c5 = g.nodes[e4].children[1]
        XCTAssertEqual(g.nodes[c5].san, "c5")
        XCTAssertEqual(g.nodes[c5].children.count, 2)
        let nf3v = g.nodes[c5].children[0]
        XCTAssertEqual(g.nodes[nf3v].children.count, 1)
        let nf3 = g.nodes[g.nodes[e4].children[0]].children[0]
        XCTAssertEqual(g.nodes[nf3].nags, [1])
        let nc6 = g.nodes[nf3].children[0]
        XCTAssertEqual(g.nodes[nc6].nags, [1])
        XCTAssertEqual(g.nodes[nc6].comment, "develop")
        XCTAssertEqual(g.result, "1/2-1/2")
    }

    func testRoundTrip() throws {
        let text = """
        [Event "Test"]
        [White "A"]
        [Black "B"]
        [Result "*"]

        1. e4 {best by test} e5 (1... c5 2. Nf3 (2. Nc3 Nc6) 2... d6) 2. Nf3 $1 Nc6 3. Bb5 *
        """
        let a = PGN.parse(text)[0].game
        let out = PGN.export(a)
        let b = PGN.parse(out)
        XCTAssertEqual(b.count, 1)
        XCTAssertNil(b[0].issue)
        XCTAssertEqual(a.nodes, b[0].game.nodes)
        XCTAssertEqual(a.result, b[0].game.result)
        // Idempotent export
        XCTAssertEqual(PGN.export(b[0].game), out)
    }

    func testOperaRoundTrip() throws {
        let a = PGN.parse(Self.opera)[0].game
        let b = PGN.parse(PGN.export(a))[0].game
        XCTAssertEqual(a.mainlineSAN, b.mainlineSAN)
        XCTAssertEqual(a.result, b.result)
        XCTAssertEqual(a.headers.count, b.headers.count)
    }

    func testMultipleGames() throws {
        let text = """
        [Event "One"]
        [Result "1-0"]

        1. e4 e5 1-0

        [Event "Two"]
        [Result "0-1"]

        1. d4 d5 0-1

        [Event "Three"]

        1. c4 *
        """
        let gs = PGN.parse(text)
        XCTAssertEqual(gs.count, 3)
        XCTAssertEqual(gs.map { $0.game.header("Event") }, ["One", "Two", "Three"])
        XCTAssertEqual(gs[1].game.mainlineSAN, ["d4", "d5"])
    }

    func testIllegalMoveReportsIssue() throws {
        let text = "1. e4 e5 2. Nf3 Nc6 3. Nf3 Nf6 4. d4 *"
        let pg = PGN.parse(text)[0]
        XCTAssertEqual(pg.issue?.moveNumber, 3)
        XCTAssertEqual(pg.issue?.san, "Nf3")
        XCTAssertEqual(pg.issue?.message, "Move 3. Nf3 is illegal in this position")
        XCTAssertEqual(pg.game.mainlineSAN, ["e4", "e5", "Nf3", "Nc6"])
        let black = PGN.parse("1. e4 e5 2. Nf3 Nf3")[0].issue
        XCTAssertEqual(black?.message, "Move 2\u{2026} Nf3 is illegal in this position")
    }

    func testFENHeaderStartPosition() throws {
        let text = """
        [SetUp "1"]
        [FEN "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1"]

        1. e4 Kd7 *
        """
        let g = PGN.parse(text)[0].game
        XCTAssertEqual(g.startPosition.fen, "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1")
        XCTAssertEqual(g.mainlineSAN, ["e4", "Kd7"])
        let again = PGN.parse(PGN.export(g))[0].game
        XCTAssertEqual(again.startPosition.fen, g.startPosition.fen)
    }

    func testSemicolonCommentsAndGluedNumbers() throws {
        let g = PGN.parse("1.e4 e5 ; a comment\n2.Nf3 Nc6 *")[0].game
        XCTAssertEqual(g.mainlineSAN, ["e4", "e5", "Nf3", "Nc6"])
    }

    func testEmptyInput() {
        XCTAssertTrue(PGN.parse("   \n").isEmpty)
    }
}

final class UCITests: XCTestCase {
    func testParseInfoCp() throws {
        let line = "info depth 18 seldepth 25 multipv 2 score cp -34 nodes 1234567 nps 2100000 hashfull 12 tbhits 0 time 587 pv e7e5 g1f3 b8c6"
        let i = try XCTUnwrap(UCI.parseInfo(line))
        XCTAssertEqual(i.depth, 18)
        XCTAssertEqual(i.seldepth, 25)
        XCTAssertEqual(i.multipv, 2)
        XCTAssertEqual(i.scoreCp, -34)
        XCTAssertNil(i.scoreMate)
        XCTAssertEqual(i.nps, 2_100_000)
        XCTAssertEqual(i.nodes, 1_234_567)
        XCTAssertEqual(i.timeMs, 587)
        XCTAssertEqual(i.pv, ["e7e5", "g1f3", "b8c6"])
        XCTAssertEqual(i.eval(whiteToMove: false), .cp(34))
        XCTAssertEqual(i.eval(whiteToMove: true), .cp(-34))
    }

    func testParseInfoMateAndBounds() throws {
        let i = try XCTUnwrap(UCI.parseInfo("info depth 20 score mate -3 lowerbound nodes 10 pv a1a2"))
        XCTAssertEqual(i.scoreMate, -3)
        XCTAssertTrue(i.isBound)
        XCTAssertEqual(i.multipv, 1)
        XCTAssertEqual(i.eval(whiteToMove: false), .mate(3))
        XCTAssertEqual(Eval.mate(3).display, "M3")
        XCTAssertEqual(Eval.mate(-2).display, "-M2")
        XCTAssertEqual(Eval.cp(40).barLabel, "+0.4")
        XCTAssertEqual(Eval.cp(-120).barLabel, "\u{2212}1.2")
        XCTAssertEqual(Eval.cp(2).barLabel, "0.0")
        XCTAssertEqual(Eval.mate(-3).barLabel, "\u{2212}M3")
        XCTAssertEqual(Eval.mate(3).plainDescription, "White mates in 3")
        XCTAssertEqual(Eval.cp(-120).plainDescription, "Black is better by 1.2 pawns")
    }

    func testIgnoresNonSearchLines() {
        XCTAssertNil(UCI.parseInfo("info string NNUE evaluation using nn-1234.nnue"))
        XCTAssertNil(UCI.parseInfo("info depth 5 currmove e2e4 currmovenumber 1"))
        XCTAssertNil(UCI.parseInfo("readyok"))
    }

    func testBestMove() {
        XCTAssertEqual(UCI.parseBestMove("bestmove e2e4 ponder e7e5")?.best, "e2e4")
        XCTAssertEqual(UCI.parseBestMove("bestmove e2e4 ponder e7e5")?.ponder, "e7e5")
        XCTAssertNil(UCI.parseBestMove("bestmove (none)")?.best)
        XCTAssertNil(UCI.parseBestMove("uciok"))
    }

    func testPVToSAN() {
        let line = Position.start.sanLine(fromUCI: ["e2e4", "e7e5", "g1f3", "zzzz", "b8c6"])
        XCTAssertEqual(line, ["e4", "e5", "Nf3"])
        XCTAssertEqual(Position.start.numberedLine(fromUCI: ["e2e4", "e7e5", "g1f3"]), "1. e4 e5 2. Nf3")
        let black = try! Position(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
        XCTAssertEqual(black.numberedLine(fromUCI: ["e7e5", "g1f3"]), "1\u{2026} e5 2. Nf3")
    }

    func testWinPercent() {
        XCTAssertEqual(Eval.cp(0).whiteWinPercent, 50, accuracy: 0.001)
        XCTAssertEqual(Eval.cp(100).whiteWinPercent, 59.1, accuracy: 0.2)
        XCTAssertEqual(Eval.mate(-1).whiteWinPercent, 0)
    }
}
