import CoreGraphics

/// A chess position read from a screenshot of a digital board.
public struct RecognizedBoard: Sendable, Equatable {
    /// FEN piece-placement field, always from White's point of view (rank 8 first).
    public var placement: String
    /// False when the screenshot shows the board from Black's side.
    public var whiteAtBottom: Bool
    /// Highlighted last-move squares in algebraic notation (e.g. ["a3", "a6"]), empty if none found.
    public var lastMoveSquares: [String]
    /// Lowest per-square classifier confidence, 0...1.
    public var confidence: Double
    /// Squares whose classification was uncertain, for the UI to flag.
    public var uncertainSquares: [String]
    /// Board rectangle in image pixel coordinates (origin top-left).
    public var boardRect: CGRect

    public init(placement: String, whiteAtBottom: Bool, lastMoveSquares: [String], confidence: Double, uncertainSquares: [String], boardRect: CGRect) {
        self.placement = placement
        self.whiteAtBottom = whiteAtBottom
        self.lastMoveSquares = lastMoveSquares
        self.confidence = confidence
        self.uncertainSquares = uncertainSquares
        self.boardRect = boardRect
    }
}

public enum BoardRecognitionError: Error, Sendable, Equatable {
    case boardNotFound
    case modelUnavailable
    case invalidPosition(String)
}

/// Finds a chessboard in an image and reads its pieces. Runs fully on device.
public final class BoardRecognizer: Sendable {
    public init() {}

    public func recognize(_ image: CGImage) async throws -> RecognizedBoard {
        throw BoardRecognitionError.modelUnavailable // TODO: implemented by the BoardVision work
    }
}
