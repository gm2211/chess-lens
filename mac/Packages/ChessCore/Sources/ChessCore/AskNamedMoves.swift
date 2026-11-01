import Foundation

/// Moves a player names in an "Ask AI" question, either as SAN ("Qd1", "Nbd2") or spoken ("queen d1",
/// "knight to f3"), and what to tell the model when such a move is not legal.
extension AskPrompt {
    /// A piece and a destination square named in a question. Pawn moves are not parsed here.
    public struct NamedMove: Equatable, Sendable {
        public var piece: PieceType
        public var square: Square
        /// SAN-like spelling used in the prompt: "Qd1".
        public var text: String { String(piece.letter) + Sq.name(square) }
        public init(piece: PieceType, square: Square) { self.piece = piece; self.square = square }
    }

    private static let sanNamed = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([KQRBN])[a-h]?[1-8]?x?([a-h][1-8])(?![A-Za-z0-9])"#)
    private static let spokenNamed = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])(king|queen|rook|bishop|knight|night)[\s-]+(?:(?:to|takes|captures|at)\s+)?([a-h])[\s-]?([1-8]|one|two|three|four|five|six|seven|eight)(?![A-Za-z0-9])"#,
        options: [.caseInsensitive])
    private static let spokenPieces: [String: PieceType] =
        ["king": .king, "queen": .queen, "rook": .rook, "bishop": .bishop, "knight": .knight, "night": .knight]
    private static let spokenDigits: [String: Int] =
        ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8]

    /// Piece moves named in `question`, in order of appearance, without repeats.
    public static func namedMoves(in question: String) -> [NamedMove] {
        let ns = question as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [(Int, NamedMove)] = []
        for m in sanNamed.matches(in: question, range: all) {
            guard let t = PieceType(letter: Character(ns.substring(with: m.range(at: 1)))),
                  let sq = Sq.parse(ns.substring(with: m.range(at: 2))) else { continue }
            found.append((m.range.location, NamedMove(piece: t, square: sq)))
        }
        for m in spokenNamed.matches(in: question, range: all) {
            let word = ns.substring(with: m.range(at: 1)).lowercased()
            let file = ns.substring(with: m.range(at: 2)).lowercased()
            let rank = ns.substring(with: m.range(at: 3)).lowercased()
            guard let t = spokenPieces[word], let r = Int(rank) ?? spokenDigits[rank],
                  let sq = Sq.parse(file + String(r)) else { continue }
            found.append((m.range.location, NamedMove(piece: t, square: sq)))
        }
        var out: [NamedMove] = []
        for (_, n) in found.sorted(by: { $0.0 < $1.0 }) where !out.contains(n) { out.append(n) }
        return out
    }

    /// SAN of the legal moves in `pos` that match the named piece and square (several if two pieces can go there).
    public static func legalSANs(for named: NamedMove, in pos: Position) -> [String] {
        pos.legalMoves().filter { $0.to == named.square && pos.piece(at: $0.from)?.type == named.piece }.map { pos.san($0) }
    }

    /// A named move that is not legal in the position asked about (nor in the one before the last move), with what
    /// the model needs to help the player anyway.
    public struct IllegalMoveNote: Equatable, Sendable {
        public var named: NamedMove
        public var text: String
        /// SAN cited in `text`; the answer may repeat these.
        public var sans: [String]
    }

    private static let pieceNames: [PieceType: String] =
        [.king: "king", .queen: "queen", .rook: "rook", .bishop: "bishop", .knight: "knight", .pawn: "pawn"]

    public static func illegalMoveNotes(question: String, subject s: Subject, limit: Int = 2) -> [IllegalMoveNote] {
        var out: [IllegalMoveNote] = []
        let pos = s.position
        for n in namedMoves(in: question) {
            if !legalSANs(for: n, in: pos).isEmpty { continue }
            if let b = s.before, !legalSANs(for: n, in: b).isEmpty { continue }
            let name = pieceNames[n.piece] ?? "piece"
            var sans: [String] = []
            var lines: [String] = ["The player mentioned \(n.text), which is not a legal move in the position above (nor in the one before the last move)."]

            let same = pos.legalMoves().filter { pos.piece(at: $0.from)?.type == n.piece }.map { pos.san($0) }
            if same.isEmpty {
                lines.append("The side to move has no legal \(name) moves.")
            } else {
                let shown = Array(same.prefix(12))
                sans += shown
                lines.append("Legal \(name) moves here: " + shown.joined(separator: ", ") + (same.count > shown.count ? ", \u{2026}" : "") + ".")
            }
            let onSquare = pos.legalMoves().filter { $0.to == n.square }.map { pos.san($0) }
            if !onSquare.isEmpty {
                sans += onSquare
                lines.append("Legal moves to \(Sq.name(n.square)): " + onSquare.joined(separator: ", ") + ".")
            }
            let line = pos.sanLine(fromUCI: s.line, maxPlies: 4)
            if !line.isEmpty {
                sans += line
                var top = "The engine's top line here: \(pos.numberedLine(fromUCI: s.line, maxPlies: 4))"
                if let e = s.evalNow { top += " (score for the side to move: \(CoachPrompt.pov(e, pos.turn)))" }
                lines.append(top + ".")
                if let first = s.line.first.flatMap({ Move(uci: $0) }), pos.piece(at: first.from)?.type == n.piece {
                    lines.append("That top move is by the same kind of piece, so it is probably what the player meant.")
                }
            }
            lines.append("Say briefly and kindly that \(n.text) is not possible, then suggest the move the player most likely meant "
                         + "(the engine's top move by that piece, or a legal move to or near that square) and answer about it.")
            out.append(IllegalMoveNote(named: n, text: lines.joined(separator: " "), sans: sans))
            if out.count == limit { break }
        }
        return out
    }
}
