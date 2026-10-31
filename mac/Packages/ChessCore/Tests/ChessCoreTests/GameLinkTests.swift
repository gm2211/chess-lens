import XCTest
@testable import ChessCore

final class GameLinkTests: XCTestCase {
    private func link(_ s: String) -> GameLink? { GameLink.parse(URL(string: s)!) }

    func testLichessGame() {
        let l = link("https://lichess.org/abcd1234")
        XCTAssertEqual(l?.kind, .lichessGame)
        XCTAssertEqual(l?.fetchURL.absoluteString, "https://lichess.org/game/export/abcd1234")
        XCTAssertEqual(l?.accept, "application/x-chess-pgn")
        XCTAssertEqual(l?.flipped, false)
    }

    func testLichessTwelveCharIDAndBlackSide() {
        let l = link("https://lichess.org/abcd1234wxyz/black#34")
        XCTAssertEqual(l?.kind, .lichessGame)
        XCTAssertEqual(l?.fetchURL.absoluteString, "https://lichess.org/game/export/abcd1234")
        XCTAssertEqual(l?.flipped, true)
        XCTAssertEqual(link("https://en.lichess.org/abcd1234/white")?.flipped, false)
    }

    func testLichessStudyChapter() {
        let l = link("https://lichess.org/study/AbCdEf12/Zy9xWv87")
        XCTAssertEqual(l?.kind, .lichessStudy)
        XCTAssertEqual(l?.fetchURL.absoluteString, "https://lichess.org/api/study/AbCdEf12/Zy9xWv87.pgn")
    }

    func testLichessNonGamePagesAreGeneric() {
        XCTAssertEqual(link("https://lichess.org/analysis")?.kind, .generic)
        XCTAssertEqual(link("https://lichess.org/training")?.kind, .generic)
        XCTAssertEqual(link("https://lichess.org/")?.kind, .generic)
    }

    func testChessCom() {
        XCTAssertEqual(link("https://www.chess.com/game/live/184727190848")?.fetchURL.absoluteString,
                       "https://www.chess.com/callback/live/game/184727190848")
        XCTAssertEqual(link("https://www.chess.com/game/live/184727190848")?.kind, .chessCom(daily: false))
        XCTAssertEqual(link("https://www.chess.com/analysis/game/live/184727190848?tab=review")?.fetchURL.absoluteString,
                       "https://www.chess.com/callback/live/game/184727190848")
        let d = link("https://chess.com/game/daily/12345678")
        XCTAssertEqual(d?.kind, .chessCom(daily: true))
        XCTAssertEqual(d?.fetchURL.absoluteString, "https://www.chess.com/callback/daily/game/12345678")
        XCTAssertEqual(link("https://www.chess.com/game/live/notanumber")?.kind, .generic)
    }

    func testGenericAndRejected() {
        let g = link("https://example.com/games/x.pgn")
        XCTAssertEqual(g?.kind, .generic)
        XCTAssertEqual(g?.fetchURL.absoluteString, "https://example.com/games/x.pgn")
        XCTAssertEqual(link("https://www.example.com/a")?.source, "example.com")
        XCTAssertNil(GameLink.parse(URL(string: "file:///tmp/a.pgn")!))
        XCTAssertNil(GameLink.parse(URL(string: "ftp://example.com/a")!))
    }

    func testURLInText() {
        XCTAssertEqual(GameLink.url(in: " https://lichess.org/abcd1234\n")?.absoluteString, "https://lichess.org/abcd1234")
        XCTAssertNil(GameLink.url(in: "see https://lichess.org/abcd1234"))
        XCTAssertNil(GameLink.url(in: "1. e4 e5"))
        XCTAssertNil(GameLink.url(in: "file:///tmp/x"))
    }
}
