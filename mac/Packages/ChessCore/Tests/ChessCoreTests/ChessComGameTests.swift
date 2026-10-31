import XCTest
@testable import ChessCore

/// Fixture: a real chess.com live game (Hikaru vs mightysmasher, 2026-10-02) as served by /callback/live/game/<id>.
final class ChessComGameTests: XCTestCase {
    static let moveList = "lB!Tgv2Uow92foZReg8!kA5Qbs0KBJQ5AIRIvK5ZKZTZcDWOdl98iyZKadKAlkARmCXHfeHzsbIACK6LkcRXcA45blXGAOGXOAXGAIGXIcUMDu2KlvK2uM7ZMV2TVDXRvKZycY57KQ7ZYP86PzyzQzRAzQAjDKjdKTZRQ0!9T2920L2TLR67RCT2ed1LCILDIS2TS7DwpwT0JR07RZ3NohNFwF"
    static let san = "d4 Nf6 Nf3 g6 g3 Bg7 Bg2 d6 O-O O-O c4 Nc6 Nc3 e5 d5 Nb8 c5 dxc5 Nxe5 Nbd7 Nxd7 Nxd7 Bf4 a6 Qd2 Re8 a4 Ne5 Rad1 Nc4 Qc2 Nd6 e4 b5 Rfe1 b4 Nb1 c4 e5 Bf5 Qc1 Nb7 Qxc4 Rb8 Nd2 Na5 Qxa6 Nb7 Qc4 Na5 Qc5 Nb7 Qc1 g5 Be3 Bxe5 Nf3 Bg7 Bxg5 Qd7 Bh6 Bf6 Bf4 Nd6 Ne5 Qxa4 Qxc7 Rbd8 Nc6 Rd7 Qb6 Rc8 Qxb4 Qxb4 Nxb4 Nc4 Nc6 Nxb2 Be5 Nxd1 Bxf6 Rd6 Ne7+ Kf8 Bg7+ Kxg7 Nxf5+ Kf6 Nxd6 Rd8 Ne4+ Kg7 Rxd1 f5 Nc5 f4 Ne6+ Kf6 Nxd8 fxg3 hxg3 Ke7 d6+ Kxd8 d7 h5 Bh1 h4 gxh4".split(separator: " ").map(String.init)
    static let json = """
    {"game":{"moveList":"\(moveList)","plyCount":109,"pgnHeaders":{"Event":"Live Chess","Site":"Chess.com","Date":"2026.10.02","White":"Hikaru","Black":"mightysmasher","Result":"1-0","WhiteElo":3451,"BlackElo":2864,"TimeControl":"180","SetUp":"1","FEN":"rnbqkbnr\\/pppppppp\\/8\\/8\\/8\\/8\\/PPPPPPPP\\/RNBQKBNR w KQkq - 0 1"}}}
    """

    func testDecodeFullGame() throws {
        let moves = try XCTUnwrap(TCN.decode(Self.moveList))
        XCTAssertEqual(moves.count, 109)
        XCTAssertEqual(moves[0].uci, "d2d4")
        XCTAssertEqual(moves[1].uci, "g8f6")
        XCTAssertEqual(moves[8].uci, "e1g1")   // castling is the king's two-square move
    }

    func testBuildGameFromJSON() throws {
        let g = try ChessComGame.parse(json: Data(Self.json.utf8))
        XCTAssertEqual(g.mainlineSAN, Self.san)
        XCTAssertEqual(g.header("White"), "Hikaru")
        XCTAssertEqual(g.header("WhiteElo"), "3451")
        XCTAssertEqual(g.result, "1-0")
        XCTAssertEqual(PGN.title(of: g), "Hikaru \u{2013} mightysmasher")
        let last = g.nodes[g.mainline().last!].position
        XCTAssertEqual(last.fen, "3k4/3P4/8/8/7P/8/5P2/3R2KB b - - 0 55")
    }

    func testPromotionCodes() throws {
        // e7-e8=Q straight, e7xd8=Q left capture, a2-a1=N (Black) straight
        let m = try XCTUnwrap(TCN.decode("0~0{i^"))
        XCTAssertEqual(m.map(\.uci), ["e7e8q", "e7d8q", "a2a1n"])
        XCTAssertEqual(TCN.decode("0}")?.first?.uci, "e7f8q")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(TCN.decode("abc"))
        XCTAssertNil(TCN.decode("a;"))
        XCTAssertEqual(TCN.decode("")?.count, 0)
    }

    func testMalformedAndIllegal() {
        XCTAssertThrowsError(try ChessComGame.parse(json: Data("{}".utf8)))
        XCTAssertThrowsError(try ChessComGame.parse(json: Data("<html>".utf8)))
        // 1. a1a2 is not legal from the start position.
        let bad = #"{"game":{"moveList":"ac","pgnHeaders":{}}}"#
        XCTAssertThrowsError(try ChessComGame.parse(json: Data(bad.utf8))) {
            XCTAssertEqual($0 as? ChessComError, .illegalMove(ply: 1))
        }
    }
}
