import XCTest
@testable import ChessCore

final class SourceAnalysisTests: XCTestCase {
    func testEvalAnnotation() {
        XCTAssertEqual(PGN.evalAnnotation("[%eval 0.23]"), .cp(23))
        XCTAssertEqual(PGN.evalAnnotation("[%eval -1.5]"), .cp(-150))
        XCTAssertEqual(PGN.evalAnnotation("[%eval 0.23,18]"), .cp(23))
        XCTAssertEqual(PGN.evalAnnotation("[%eval #3]"), .mate(3))
        XCTAssertEqual(PGN.evalAnnotation("[%eval #-2]"), .mate(-2))
        XCTAssertEqual(PGN.evalAnnotation("[%eval #-2,30]"), .mate(-2))
        XCTAssertEqual(PGN.evalAnnotation("Best. [%clk 0:01:00] [%eval 1.1] ok"), .cp(110))
        XCTAssertNil(PGN.evalAnnotation("[%clk 0:01:00]"))
        XCTAssertNil(PGN.evalAnnotation("[%eval abc]"))
        XCTAssertNil(PGN.evalAnnotation("[%eval #0]"))
        XCTAssertNil(PGN.evalAnnotation("plain comment"))
    }

    func testParsesChessgamesComputerAnalysis() throws {
        let games = PGN.parse(Self.chessgamesComp)
        XCTAssertEqual(games.count, 1)
        let g = try XCTUnwrap(games.first).game
        XCTAssertEqual(g.nodes.count, 34)   // 33 plies + the root
        XCTAssertEqual(g.header("White"), "Paul Morphy")
        XCTAssertEqual(g.nodes[1].comment, "Notes by Stockfish 8 v270317 (minimum 60s/ply)")
        XCTAssertTrue(g.nodes.contains { ($0.comment ?? "").contains("+2.72 (42 ply)") })
        XCTAssertEqual(g.nodes.filter { $0.comment != nil }.count, 11)
        XCTAssertEqual(g.nodes.last?.san, "Rd8#")
    }

    func testLichessEvalCommentsParse() throws {
        let g = try XCTUnwrap(PGN.parse("1. e4 { [%eval 0.17] [%clk 0:03:00] } e5 { [%eval 0.2] } 2. Qh5 { [%eval -0.9] Inaccuracy. Nf3 was best. } (2. Nf3 Nc6) *").first).game
        XCTAssertEqual(PGN.evalAnnotation(g.nodes[1].comment ?? ""), .cp(17))
        XCTAssertEqual(PGN.evalAnnotation(g.nodes[3].comment ?? ""), .cp(-90))
        XCTAssertEqual(g.nodes[2].children.count, 2)
    }

    static let chessgamesComp = """
[Event "Paris"]
[Site "Paris FRA"]
[Date "1858.??.??"]
[EventDate "?"]
[Round "?"]
[Result "1-0"]
[White "Paul Morphy"]
[Black "Duke Karl / Count Isouard"]
[ECO "C41"]
[WhiteElo "?"]
[BlackElo "?"]
[PlyCount "33"]

1.e4 {Notes by Stockfish 8 v270317 (minimum 60s/ply)} e5 2.Nf3
d6 3.d4 Bg4 {better is 3...Nf6 4.Nc3 exd4 5.Nxd4 Nc6 6.Bc4 Be7
7.O-O O-O = +0.23 (37 ply)} 4.dxe5 {+/= +0.95 (34 ply)} Bxf3
5.Qxf3 {5.gxf3 was played in Breyer vs R Binder, 1921 (1-0)}
dxe5 6.Bc4 {6.Qb3 was played in V Neverov vs M Chahrour, 2009
(1-0)} Nf6 7.Qb3 {7.Bg5 was played in M Spaeti vs J
Soltermann, 2005 (1-0)} Qe7 8.Nc3 {8.Qxb7 was played in A
Milovic vs D Mihajlova, 2008 (1-0)} c6 9.Bg5 b5 {? 9...Na6
10.Bxa6 bxa6 11.Rd1 Qb4 12.Ke2 a5 13.Rd3 Be7 +/- +1.54 (41
ply)} 10.Nxb5 {+- +2.72 (42 ply)} cxb5 {? 10...Qb4+ 11.Qxb4
Bxb4+ 12.c3 cxb5 13.Bxb5+ Nbd7 14.cxb4 +- +2.79 (39 ply)}
11.Bxb5+ {+- +7.42 (39 ply)} Nbd7 12.O-O-O Rd8 13.Rxd7 Rxd7
14.Rd1 Qe6 15.Bxd7+ Nxd7 16.Qb8+ Nxb8 17.Rd8# 1-0
"""
}
