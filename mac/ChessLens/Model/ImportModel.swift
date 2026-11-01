import Foundation
import Observation
import AppKit
import ChessCore
import BoardVision

enum ImportTab: String, CaseIterable, Identifiable {
    case pgn = "PGN", fen = "FEN", screenshot = "Screenshot", setup = "Set Up"
    var id: String { rawValue }
}

enum ClipboardKind: Equatable {
    case fen(String)
    case pgn(String)
    case unknown
}

enum ImportDetect {
    /// Looks at pasted text and decides whether it is a FEN or a PGN.
    static func classify(_ text: String) -> ClipboardKind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .unknown }
        if !t.contains("\n"), looksLikeFEN(t) { return .fen(t) }
        if t.contains("[") && t.contains("\"") { return .pgn(t) }
        // Movetext: a move number followed by a move, or a bare result
        if t.range(of: #"(^|\s)\d+\s*\.(\.\.)?\s*[A-Za-z]"#, options: .regularExpression) != nil { return .pgn(t) }
        return .unknown
    }

    static func looksLikeFEN(_ t: String) -> Bool {
        let first = t.split(separator: " ").first.map(String.init) ?? ""
        guard first.filter({ $0 == "/" }).count == 7 else { return false }
        return first.allSatisfy { "12345678pnbrqkPNBRQK/".contains($0) }
    }
}

/// Position read from a screenshot, being corrected by the user before loading.
struct ScreenshotDraft {
    var board: [Piece?]                // squares from White's point of view (a1 = 0)
    var uncertain: Set<Square>
    var sideToMove: Side
    var castling: CastlingRights
    var blackAtBottom: Bool
    var confidence: Double

    var placement: String {
        Position(board: board, turn: sideToMove, castling: castling, epSquare: nil, halfmove: 0, fullmove: 1).placementFEN
    }

    var position: Position {
        var p = Position(board: board, turn: sideToMove, castling: castling, epSquare: nil, halfmove: 0, fullmove: 1)
        p.sanitizeCastlingPublic()
        return p
    }

    mutating func setPlacement(_ text: String) -> Bool {
        guard let b = try? Position.parseBoard(text.trimmingCharacters(in: .whitespaces)) else { return false }
        board = b
        return true
    }

    mutating func rotate180() {
        board = Array(board.reversed())
        uncertain = Set(uncertain.map { 63 - $0 })
        blackAtBottom.toggle()
    }

    static let emptyBoard = [Piece?](repeating: nil, count: 64)
    static var startingBoard: [Piece?] { ((try? Position(fen: Position.startFEN))?.board ?? emptyBoard) }

    static func empty() -> ScreenshotDraft {
        ScreenshotDraft(board: emptyBoard, uncertain: [], sideToMove: .white, castling: [], blackAtBottom: false, confidence: 1)
    }

    /// Editable draft seeded from an existing position.
    static func from(_ p: Position, flipped: Bool) -> ScreenshotDraft {
        ScreenshotDraft(board: p.board, uncertain: [], sideToMove: p.turn,
                        castling: p.castling.intersection(possibleCastling(p.board)),
                        blackAtBottom: flipped, confidence: 1)
    }

    /// Castling rights the piece placement allows.
    static func possibleCastling(_ board: [Piece?]) -> CastlingRights {
        var r: CastlingRights = []
        if board[4] == Piece(.white, .king) {
            if board[7] == Piece(.white, .rook) { r.insert(.whiteKingside) }
            if board[0] == Piece(.white, .rook) { r.insert(.whiteQueenside) }
        }
        if board[60] == Piece(.black, .king) {
            if board[63] == Piece(.black, .rook) { r.insert(.blackKingside) }
            if board[56] == Piece(.black, .rook) { r.insert(.blackQueenside) }
        }
        return r
    }
}

extension Position {
    /// Drops castling rights that the placement cannot support.
    mutating func sanitizeCastlingPublic() {
        castling.formIntersection(ScreenshotDraft.possibleCastling(board))
    }
}

@Observable @MainActor
final class ImportModel {
    var tab: ImportTab = .pgn

    // PGN
    var pgnText = "" { didSet { if pgnText != oldValue { reparsePGN() } } }
    private(set) var games: [ParsedGame] = []
    var selectedGame = 0

    // FEN
    var fenText = ""

    // Set Up (manual editor, seeded from the current board)
    var setupDraft: ScreenshotDraft?

    func seedSetup(from position: Position, flipped: Bool) {
        setupDraft = .from(position, flipped: flipped)
    }

    // Screenshot
    enum ShotState { case idle, working, failed(String), confirm }
    var shotState: ShotState = .idle
    var shotImage: NSImage?
    var draft: ScreenshotDraft?
    private var recognitionTask: Task<Void, Never>?

    var parsedSelected: ParsedGame? { games.indices.contains(selectedGame) ? games[selectedGame] : nil }

    func reset() {
        pgnText = ""; fenText = ""; games = []; selectedGame = 0
        cancelScreenshot()
        shotState = .idle; shotImage = nil; draft = nil; setupDraft = nil
    }

    private func reparsePGN() {
        let t = pgnText.trimmingCharacters(in: .whitespacesAndNewlines)
        games = t.isEmpty ? [] : PGN.parse(t)
        selectedGame = 0
    }

    // MARK: FEN

    enum FENStatus: Equatable {
        case empty
        case valid(Position)
        case invalid(String)
    }

    var fenStatus: FENStatus {
        let t = fenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .empty }
        do {
            var p = try Position(fen: t)
            // A bare piece placement has no castling info: keep what is possible.
            if t.split(separator: " ").count <= 2 {
                p.castling = ScreenshotDraft.possibleCastling(p.board)
            }
            return .valid(p)
        } catch { return .invalid((error as? ChessError)?.errorDescription ?? error.localizedDescription) }
    }

    // MARK: Screenshot

    func cancelScreenshot() {
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    func recognize(image: NSImage) {
        cancelScreenshot()
        tab = .screenshot
        shotImage = image
        shotState = .working
        draft = nil
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            shotState = .failed("That image could not be read.")
            return
        }
        recognitionTask = Task { [weak self] in
            do {
                let result = try await BoardRecognizer().recognize(cg)
                if Task.isCancelled { return }
                self?.finishRecognition(result)
            } catch {
                if Task.isCancelled { return }
                self?.shotState = .failed(Self.message(for: error))
            }
        }
    }

    static func message(for error: Error) -> String {
        switch error as? BoardRecognitionError {
        case .modelUnavailable?: "Screenshot reading isn't available in this build."
        case .boardNotFound?: "No chessboard was found in that image. Try a tighter crop of the board."
        case .invalidPosition(let why)?: "The board was found but the position doesn't look right (\(why)). You can still correct it by hand."
        case nil: error.localizedDescription
        }
    }

    private func finishRecognition(_ r: RecognizedBoard) {
        draft = Self.makeDraft(r)
        shotState = .confirm
    }

    /// Turns a recognition result into an editable draft.
    static func makeDraft(_ r: RecognizedBoard) -> ScreenshotDraft {
        let board = (try? Position.parseBoard(r.placement)) ?? [Piece?](repeating: nil, count: 64)
        // The side that just moved owns the piece on one of the highlighted squares.
        var toMove = Side.white
        for name in r.lastMoveSquares {
            if let sq = Sq.parse(name), let p = board[sq] { toMove = p.color.opposite; break }
        }
        return ScreenshotDraft(
            board: board,
            uncertain: Set(r.uncertainSquares.compactMap(Sq.parse)),
            sideToMove: toMove,
            castling: ScreenshotDraft.possibleCastling(board),
            blackAtBottom: !r.whiteAtBottom,
            confidence: r.confidence)
    }

    /// Shows an already-read screenshot in the editor (used by the drop confirmation card).
    func adopt(image: NSImage, draft: ScreenshotDraft) {
        cancelScreenshot()
        tab = .screenshot
        shotImage = image
        self.draft = draft
        shotState = .confirm
    }

    func startManualDraft() {
        draft = .empty()
        shotState = .confirm
    }
}
