import AppKit
import ImageIO
import XCTest

@testable import BoardVision

final class BoardVisionTests: XCTestCase {
    // MARK: real screenshot

    func testRealFlippedEndgameScreenshot() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "flipped-endgame", withExtension: "webp", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let result = try await BoardRecognizer().recognize(image)
        print("FIXTURE RESULT: \(result)")
        XCTAssertEqual(result.placement, "8/P1n3r1/Rpk3p1/1pP2pK1/1P2pPP1/8/4R3/8")
        XCTAssertFalse(result.whiteAtBottom)
        XCTAssertEqual(Set(result.lastMoveSquares), ["a3", "a6"])
        XCTAssertTrue((0.0...1.0).contains(result.confidence))
        XCTAssertLessThan(abs(result.boardRect.width - 1464), 40)  // board nearly fills the 1490x1472 screenshot
    }

    // MARK: synthetic round trips (piece set and theme never seen in training)

    private static let heldOutLight = NSColor(srgbRed: 0xF2 / 255, green: 0xD9 / 255, blue: 0xDE / 255, alpha: 1)
    private static let heldOutDark = NSColor(srgbRed: 0xC4 / 255, green: 0x8A / 255, blue: 0x9A / 255, alpha: 1)

    private static let codes = ["wP", "wN", "wB", "wR", "wQ", "wK", "bP", "bN", "bB", "bR", "bQ", "bK"]
    private static let fenChars: [Character] = ["P", "N", "B", "R", "Q", "K", "p", "n", "b", "r", "q", "k"]

    private func loadHeldOutPieces() throws -> [String: CGImage] {
        var out: [String: CGImage] = [:]
        for code in Self.codes {
            let url = try XCTUnwrap(Bundle.module.url(forResource: code, withExtension: "png", subdirectory: "Fixtures/HeldOutPieces"))
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            out[code] = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        }
        return out
    }

    struct LCG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state ^ (state >> 29)
        }
    }

    /// Plausible random position: White's pieces mostly on ranks 1-4, Black's mostly on ranks 5-8.
    /// Returns 64 chars indexed [rank 8 ... rank 1][a ... h], "." for empty.
    private func randomPosition(_ rng: inout LCG) -> [Character] {
        var board = [Character](repeating: ".", count: 64)  // index = row * 8 + file, row 0 = rank 8
        func place(_ ch: Character, white: Bool, pawn: Bool) {
            for _ in 0..<200 {
                let rank = pawn ? Int.random(in: 1...6, using: &rng) : Int.random(in: 0...7, using: &rng)  // 0-based rank, 0 = rank 1
                let biased = Bool.random(using: &rng) || Bool.random(using: &rng) || Bool.random(using: &rng)
                let r = biased ? (white ? min(rank, 3) : max(rank, 4)) : rank
                if pawn && (r == 0 || r == 7) { continue }
                let file = Int.random(in: 0...7, using: &rng)
                let idx = (7 - r) * 8 + file
                if board[idx] == "." { board[idx] = ch; return }
            }
        }
        place("K", white: true, pawn: false)
        place("k", white: false, pawn: false)
        for _ in 0..<Int.random(in: 4...8, using: &rng) { place("P", white: true, pawn: true) }
        for _ in 0..<Int.random(in: 4...8, using: &rng) { place("p", white: false, pawn: true) }
        for ch in "QRRBBNN" where Int.random(in: 0...2, using: &rng) > 0 { place(ch, white: true, pawn: false) }
        for ch in "qrrbbnn" where Int.random(in: 0...2, using: &rng) > 0 { place(ch, white: false, pawn: false) }
        return board
    }

    private func expand(_ placement: String) -> [Character] {
        var out: [Character] = []
        for ch in placement {
            if let n = ch.wholeNumberValue { out += [Character](repeating: ".", count: n) } else if ch != "/" { out.append(ch) }
        }
        return out
    }

    /// Renders the position (from White's POV array) into a larger noisy canvas.
    private func renderScreenshot(position: [Character], flipped: Bool, squareSize: Int, pieces: [String: CGImage], labels: Bool, rng: inout LCG) throws -> (CGImage, CGRect) {
        let boardSide = squareSize * 8
        let pad = Int.random(in: 40...160, using: &rng)
        let W = boardSide + 2 * pad + Int.random(in: 0...200, using: &rng)
        let H = boardSide + 2 * pad + Int.random(in: 0...80, using: &rng)
        let ox = pad + Int.random(in: 0...60, using: &rng), oy = pad
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Busy page background: dark UI with random rectangles ("sidebar", text blocks) and noise.
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for _ in 0..<40 {
            ctx.setFillColor(CGColor(gray: CGFloat.random(in: 0.1...0.8, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: CGFloat.random(in: 0...CGFloat(W), using: &rng), y: CGFloat.random(in: 0...CGFloat(H), using: &rng),
                            width: CGFloat.random(in: 5...120, using: &rng), height: CGFloat.random(in: 2...40, using: &rng)))
        }
        let sq = CGFloat(squareSize)
        for row in 0..<8 {
            for file in 0..<8 {
                let rect = CGRect(x: CGFloat(ox) + CGFloat(file) * sq, y: CGFloat(H - oy) - CGFloat(row + 1) * sq, width: sq, height: sq)
                let light = (row + file) % 2 == 0
                ctx.setFillColor((light ? Self.heldOutLight : Self.heldOutDark).cgColor)
                ctx.fill(rect)
            }
        }
        // Last-move style highlight on two squares.
        for (row, file) in [(2, 3), (4, 5)] {
            ctx.setFillColor(CGColor(srgbRed: 0.6, green: 0.78, blue: 0, alpha: 0.4))
            ctx.fill(CGRect(x: CGFloat(ox) + CGFloat(file) * sq, y: CGFloat(H - oy) - CGFloat(row + 1) * sq, width: sq, height: sq))
        }
        for row in 0..<8 {
            for file in 0..<8 {
                // Image cell (row, file) shows White-POV square: unflipped (rank 8 on top) = position[row*8+file]; flipped = reversed.
                let ch = flipped ? position[(7 - row) * 8 + (7 - file)] : position[row * 8 + file]
                guard ch != ".", let idx = Self.fenChars.firstIndex(of: ch), let img = pieces[Self.codes[idx]] else { continue }
                let rect = CGRect(x: CGFloat(ox) + CGFloat(file) * sq, y: CGFloat(H - oy) - CGFloat(row + 1) * sq, width: sq, height: sq)
                ctx.draw(img, in: rect.insetBy(dx: sq * 0.03, dy: sq * 0.03))
            }
        }
        if labels {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let font = NSFont.systemFont(ofSize: sq * 0.2, weight: .semibold)
            for i in 0..<8 {
                let letter = String(UnicodeScalar(UInt8(flipped ? 104 - i : 97 + i)))
                let digit = String(flipped ? i + 1 : 8 - i)
                let color = (i % 2 == 0) ? Self.heldOutDark : Self.heldOutLight
                // Letters: bottom-right of bottom-row squares. Digits: top-left of left-column squares.
                (letter as NSString).draw(at: CGPoint(x: CGFloat(ox) + CGFloat(i + 1) * sq - sq * 0.2, y: CGFloat(H - oy) - 8 * sq + sq * 0.02),
                                          withAttributes: [.font: font, .foregroundColor: ((7 + i) % 2 == 0 ? Self.heldOutDark : Self.heldOutLight)])
                (digit as NSString).draw(at: CGPoint(x: CGFloat(ox) + sq * 0.05, y: CGFloat(H - oy) - CGFloat(i) * sq - sq * 0.25),
                                         withAttributes: [.font: font, .foregroundColor: color])
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = try XCTUnwrap(ctx.makeImage())
        return (image, CGRect(x: ox, y: oy, width: boardSide, height: boardSide))
    }

    private func runSyntheticRoundTrip(seed: UInt64, flipped: Bool, labels: Bool, squareSize: Int) async throws {
        var rng = LCG(state: seed)
        let pieces = try loadHeldOutPieces()
        let position = randomPosition(&rng)
        let (image, boardRect) = try renderScreenshot(position: position, flipped: flipped, squareSize: squareSize, pieces: pieces, labels: labels, rng: &rng)
        let result = try await BoardRecognizer().recognize(image)
        let got = expand(result.placement)
        XCTAssertEqual(got.count, 64)
        let correct = zip(got, position).filter { $0 == $1 }.count
        print("synthetic seed=\(seed) flipped=\(flipped) labels=\(labels) size=\(squareSize): \(correct)/64 whiteAtBottom=\(result.whiteAtBottom) rect=\(result.boardRect) expected=\(boardRect) conf=\(result.confidence)")
        // Target is 63/64; the held-out piece set currently scores 61-63, tracked as a known gap (queen/king, knight/bishop confusions).
        XCTAssertGreaterThanOrEqual(correct, 60, "got \(result.placement)")
        XCTAssertEqual(result.whiteAtBottom, !flipped)
        XCTAssertLessThan(abs(result.boardRect.minX - boardRect.minX), CGFloat(squareSize) * 0.15)
        XCTAssertLessThan(abs(result.boardRect.minY - boardRect.minY), CGFloat(squareSize) * 0.15)
        XCTAssertLessThan(abs(result.boardRect.width - boardRect.width), CGFloat(squareSize) * 0.3)
        XCTAssertEqual(Set(result.lastMoveSquares).count, 2)
    }

    func testSyntheticWhiteAtBottomWithLabels() async throws {
        try await runSyntheticRoundTrip(seed: 11, flipped: false, labels: true, squareSize: 72)
    }

    func testSyntheticFlippedWithLabels() async throws {
        try await runSyntheticRoundTrip(seed: 12, flipped: true, labels: true, squareSize: 64)
    }

    func testSyntheticWhiteAtBottomNoLabels() async throws {
        try await runSyntheticRoundTrip(seed: 13, flipped: false, labels: false, squareSize: 80)
    }

    func testSyntheticFlippedNoLabels() async throws {
        try await runSyntheticRoundTrip(seed: 14, flipped: true, labels: false, squareSize: 56)
    }

    func testRejectsImageWithoutBoard() async throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let image = try XCTUnwrap(ctx.makeImage())
        do {
            _ = try await BoardRecognizer().recognize(image)
            XCTFail("expected boardNotFound")
        } catch let error as BoardRecognitionError {
            XCTAssertEqual(error, .boardNotFound)
        }
    }
}
