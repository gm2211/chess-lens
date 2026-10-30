import Foundation

public enum Side: Int, Sendable, Hashable, CaseIterable {
    case white = 0, black = 1
    public var opposite: Side { self == .white ? .black : .white }
}

public enum PieceType: Int, Sendable, Hashable, CaseIterable {
    case pawn = 1, knight, bishop, rook, queen, king

    /// Uppercase letter used in SAN/FEN (pawn is "P" in FEN only).
    public var letter: Character {
        switch self {
        case .pawn: "P"
        case .knight: "N"
        case .bishop: "B"
        case .rook: "R"
        case .queen: "Q"
        case .king: "K"
        }
    }

    public init?(letter: Character) {
        switch Character(letter.uppercased()) {
        case "P": self = .pawn
        case "N": self = .knight
        case "B": self = .bishop
        case "R": self = .rook
        case "Q": self = .queen
        case "K": self = .king
        default: return nil
        }
    }
}

public struct Piece: Sendable, Hashable {
    public var color: Side
    public var type: PieceType
    public init(_ color: Side, _ type: PieceType) { self.color = color; self.type = type }

    public var fenChar: Character {
        let c = type.letter
        return color == .white ? c : Character(c.lowercased())
    }

    public init?(fen c: Character) {
        guard let t = PieceType(letter: c) else { return nil }
        self.init(c.isUppercase ? .white : .black, t)
    }

    /// Asset name, e.g. "wk", "bp" (matches the cburnett image set).
    public var assetName: String { (color == .white ? "w" : "b") + String(Character(type.letter.lowercased())) }
}

/// Squares are 0...63 with a1 = 0, b1 = 1 ... h8 = 63.
public typealias Square = Int

public enum Sq {
    @inline(__always) public static func file(_ s: Square) -> Int { s & 7 }
    @inline(__always) public static func rank(_ s: Square) -> Int { s >> 3 }
    @inline(__always) public static func make(file: Int, rank: Int) -> Square { rank * 8 + file }
    public static func name(_ s: Square) -> String {
        String(UnicodeScalar(UInt8(97 + file(s)))) + String(rank(s) + 1)
    }
    public static func parse(_ name: String) -> Square? {
        let u = Array(name.utf8)
        guard u.count == 2, u[0] >= 97, u[0] <= 104, u[1] >= 49, u[1] <= 56 else { return nil }
        return Int(u[1] - 49) * 8 + Int(u[0] - 97)
    }
    public static func isLight(_ s: Square) -> Bool { (file(s) + rank(s)) % 2 == 1 }
}

public struct CastlingRights: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let whiteKingside = CastlingRights(rawValue: 1)
    public static let whiteQueenside = CastlingRights(rawValue: 2)
    public static let blackKingside = CastlingRights(rawValue: 4)
    public static let blackQueenside = CastlingRights(rawValue: 8)
    public static let all: CastlingRights = [.whiteKingside, .whiteQueenside, .blackKingside, .blackQueenside]

    public var fen: String {
        var s = ""
        if contains(.whiteKingside) { s += "K" }
        if contains(.whiteQueenside) { s += "Q" }
        if contains(.blackKingside) { s += "k" }
        if contains(.blackQueenside) { s += "q" }
        return s.isEmpty ? "-" : s
    }
}

public struct Move: Sendable, Hashable {
    public var from: Square
    public var to: Square
    public var promotion: PieceType?
    public init(from: Square, to: Square, promotion: PieceType? = nil) {
        self.from = from; self.to = to; self.promotion = promotion
    }

    /// Long algebraic / UCI notation: "e2e4", "e7e8q". Castling is the king's two-square move.
    public var uci: String {
        Sq.name(from) + Sq.name(to) + (promotion.map { String(Character($0.letter.lowercased())) } ?? "")
    }

    public init?(uci: String) {
        let c = Array(uci)
        guard c.count == 4 || c.count == 5,
              let f = Sq.parse(String(c[0...1])), let t = Sq.parse(String(c[2...3])) else { return nil }
        var promo: PieceType?
        if c.count == 5 {
            guard let p = PieceType(letter: c[4]), p != .pawn, p != .king else { return nil }
            promo = p
        }
        self.init(from: f, to: t, promotion: promo)
    }
}

public enum ChessError: Error, Equatable, Sendable, LocalizedError {
    case invalidFEN(String)
    case illegalMove(String)
    case ambiguousMove(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFEN(let s): "Invalid FEN: \(s)"
        case .illegalMove(let s): "Illegal move: \(s)"
        case .ambiguousMove(let s): "Ambiguous move: \(s)"
        }
    }
}
