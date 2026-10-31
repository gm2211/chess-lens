import Foundation

/// chess.com's TCN move encoding: two characters per move, each an index 0...63 into `alphabet`
/// (a1 = 0 ... h8 = 63). A second index above 63 marks a pawn promotion.
public enum TCN {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!?{~}(^)[_]@#$")
    private static let promotions: [PieceType] = [.queen, .knight, .rook, .bishop]

    /// Decodes a move list. Returns nil for odd lengths, unknown characters or impossible promotion codes.
    public static func decode(_ tcn: String) -> [Move]? {
        let chars = Array(tcn)
        guard chars.count % 2 == 0 else { return nil }
        var moves: [Move] = []
        moves.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let from = alphabet.firstIndex(of: chars[i]), from < 64,
                  let code = alphabet.firstIndex(of: chars[i + 1]) else { return nil }
            if code < 64 {
                moves.append(Move(from: from, to: code))
            } else {
                // Promotion: the code carries the piece and which file the pawn lands on (left capture, straight, right capture).
                let piece = (code - 64) / 3
                guard piece < promotions.count else { return nil }
                let to = from + (from < 16 ? -8 : 8) + (code - 64) % 3 - 1
                guard (0..<64).contains(to) else { return nil }
                moves.append(Move(from: from, to: to, promotion: promotions[piece]))
            }
        }
        return moves
    }
}

public enum ChessComError: Error, Equatable {
    case malformed
    case illegalMove(ply: Int)
}

/// Builds a `Game` from the JSON behind chess.com's `/callback/live/game/<id>` endpoint.
public enum ChessComGame {
    public static func parse(json: Data) throws -> Game {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let game = root["game"] as? [String: Any],
              let tcn = game["moveList"] as? String,
              let moves = TCN.decode(tcn) else { throw ChessComError.malformed }

        var headers: [String: String] = [:]
        for (k, v) in (game["pgnHeaders"] as? [String: Any]) ?? [:] {
            if let s = v as? String { headers[k] = s } else if let n = v as? NSNumber { headers[k] = n.stringValue }
        }
        var start = Position.start
        if let fen = headers["FEN"], let p = try? Position(fen: fen) { start = p }

        var g = Game(startPosition: start)
        let order = ["Event", "Site", "Date", "Round", "White", "Black", "Result"]
        for k in order { if let v = headers[k] { g.setHeader(k, v) } }
        for k in headers.keys.sorted() where !order.contains(k) && k != "FEN" && k != "SetUp" { g.setHeader(k, headers[k]!) }
        if let r = headers["Result"] { g.result = r }

        var cur = 0
        for (i, m) in moves.enumerated() {
            guard let id = try? g.addMove(m, after: cur) else { throw ChessComError.illegalMove(ply: i + 1) }
            cur = id
        }
        return g
    }
}
