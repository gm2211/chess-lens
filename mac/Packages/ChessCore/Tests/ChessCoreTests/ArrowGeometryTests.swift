import XCTest
@testable import ChessCore

final class ArrowGeometryTests: XCTestCase {
    func sq(_ s: String) -> Square { Sq.parse(s)! }
    func c(_ s: String) -> ArrowCandidate { ArrowCandidate(from: sq(String(s.prefix(2))), to: sq(String(s.suffix(2)))) }

    func testKnightDetection() {
        XCTAssertTrue(ArrowGeometry.isKnightMove(from: sq("g1"), to: sq("f3")))
        XCTAssertTrue(ArrowGeometry.isKnightMove(from: sq("b8"), to: sq("c6")))
        XCTAssertTrue(ArrowGeometry.isKnightMove(from: sq("e4"), to: sq("c3")))
        XCTAssertFalse(ArrowGeometry.isKnightMove(from: sq("e2"), to: sq("e4")))
        XCTAssertFalse(ArrowGeometry.isKnightMove(from: sq("a1"), to: sq("c3")))
        XCTAssertFalse(ArrowGeometry.isKnightMove(from: sq("a1"), to: sq("a1")))
    }

    func testCollinearSameOriginKeepsBestAndMarksOther() {
        let r = ArrowGeometry.resolveOverlaps([c("d7d5"), c("d7d6"), c("g8f6")])
        XCTAssertEqual(r.arrows, [c("d7d5"), c("g8f6")])
        XCTAssertEqual(r.dots, [sq("d6")])
    }

    func testBestShortOneDropsLongerCollinear() {
        let r = ArrowGeometry.resolveOverlaps([c("d7d6"), c("d7d5")])
        XCTAssertEqual(r.arrows, [c("d7d6")])
        XCTAssertEqual(r.dots, [sq("d5")])
    }

    func testDifferentDirectionsSameOriginBothKept() {
        let r = ArrowGeometry.resolveOverlaps([c("d7d5"), c("d7c6")])
        XCTAssertEqual(r.arrows.count, 2)
        XCTAssertTrue(r.dots.isEmpty)
    }

    func testSharedTargetKeepsOnlyBest() {
        let r = ArrowGeometry.resolveOverlaps([c("g1f3"), c("d2f3")])
        XCTAssertEqual(r.arrows, [c("g1f3")])
        XCTAssertTrue(r.dots.isEmpty)
    }

    func testAlternativeOpacityFades() {
        XCTAssertEqual(ArrowGeometry.alternativeOpacity(gap: 1), 0.55, accuracy: 1e-9)
        XCTAssertEqual(ArrowGeometry.alternativeOpacity(gap: 9), 0.40, accuracy: 1e-9)
        XCTAssertEqual(ArrowGeometry.alternativeOpacity(gap: 30), 0.25, accuracy: 1e-9)
    }

    func testStraightShapeTipAndPolygon() throws {
        let s = try XCTUnwrap(ArrowGeometry.shape(from: .init(x: 0, y: 0), to: .init(x: 200, y: 0), cell: 100, primary: true, knight: false))
        XCTAssertEqual(s.polygon.count, 7)
        let tip = s.polygon[3]
        XCTAssertEqual(tip.x, 200 - 8, accuracy: 1e-9)
        XCTAssertEqual(tip.y, 0, accuracy: 1e-9)
        XCTAssertEqual(s.capCenter.x, 25, accuracy: 1e-9)
    }

    func testKnightShapeIsLShaped() throws {
        // e4 -> f6 on screen: two cells up, one right: long leg vertical, corner above the origin.
        let s = try XCTUnwrap(ArrowGeometry.shape(from: .init(x: 0, y: 200), to: .init(x: 100, y: 0), cell: 100, primary: true, knight: true))
        XCTAssertEqual(s.polygon.count, 9)
        // Both shaft edges pass the corner at x = 0 +/- half width.
        let xs = s.polygon.map(\.x)
        XCTAssertTrue(xs.contains { abs($0 - 9) < 1e-9 } && xs.contains { abs($0 + 9) < 1e-9 })
    }
}
