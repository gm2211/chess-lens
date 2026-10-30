import CoreGraphics
import Foundation

enum RecognitionPipeline {
    /// Squares whose chosen class has probability below this are reported as uncertain.
    static let uncertaintyThreshold: Float = 0.7
    /// Longest side of the downscaled copy used for board localization.
    static let analysisSize = 1000

    private static let net: PieceNet? = PieceNet.loadBundled()

    static func run(_ image: CGImage) throws -> RecognizedBoard {
        guard let net else { throw BoardRecognitionError.modelUnavailable }
        guard let raster = RasterImage(image, maxDimension: analysisSize),
              let grid = BoardLocator(raster).locate() else { throw BoardRecognitionError.boardNotFound }
        let k = raster.scale
        let geometry = BoardGeometry(x0: grid.x0 / k, y0: grid.y0 / k, side: grid.s / k)

        // Classify squares as drawn (image orientation, row 0 = top).
        let probs = SquareClassifier.classify(image, geometry: geometry, net: net)
        let raw = probs.map { p in p.enumerated().max { $0.element < $1.element }!.offset }

        let votes = OrientationDetector.readLabels(image, geometry: geometry)
        let whiteAtBottom = OrientationDetector.decide(votes: votes, balance: OrientationDetector.pieceBalance(raw))

        func whiteSquare(row: Int, file: Int) -> Int {
            whiteAtBottom ? (7 - row) * 8 + file : row * 8 + (7 - file)
        }
        var whitePOV = [[Float]](repeating: [], count: 64)
        for row in 0..<8 { for file in 0..<8 { whitePOV[whiteSquare(row: row, file: file)] = probs[row * 8 + file] } }
        let resolved = PositionValidator.resolve(whitePOV)

        var lastMove: [String] = []
        let cells = LastMoveDetector.detect(raster, grid: grid)
        if cells.count == 2 {
            var sqs = cells.map { whiteSquare(row: $0.row, file: $0.file) }
            // Order as [from, to]: the origin square is empty after the move.
            if resolved.classes[sqs[1]] == 0 && resolved.classes[sqs[0]] != 0 { sqs.reverse() }
            lastMove = sqs.map(PositionValidator.squareName)
        }

        let uncertain = (0..<64).filter { resolved.confidence[$0] < uncertaintyThreshold }.map(PositionValidator.squareName)
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return RecognizedBoard(
            placement: PositionValidator.fen(resolved.classes),
            whiteAtBottom: whiteAtBottom,
            lastMoveSquares: lastMove,
            confidence: Double(resolved.confidence.min() ?? 0),
            uncertainSquares: uncertain,
            boardRect: geometry.rect.intersection(bounds)
        )
    }
}
