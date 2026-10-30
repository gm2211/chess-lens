import Foundation

extension Position {
    /// Standard Algebraic Notation for a legal move in this position (with +/# suffix).
    public func san(_ m: Move) -> String {
        guard let piece = board[m.from] else { return m.uci }
        var s = ""
        if piece.type == .king, abs(Sq.file(m.to) - Sq.file(m.from)) == 2 {
            s = m.to > m.from ? "O-O" : "O-O-O"
        } else {
            let isCapture = board[m.to] != nil || (piece.type == .pawn && Sq.file(m.from) != Sq.file(m.to))
            if piece.type == .pawn {
                if isCapture { s += String(Character(UnicodeScalar(UInt8(97 + Sq.file(m.from))))) + "x" }
            } else {
                s.append(piece.type.letter)
                let others = legalMoves().filter { $0.to == m.to && $0.from != m.from && board[$0.from] == piece }
                if !others.isEmpty {
                    let sameFile = others.contains { Sq.file($0.from) == Sq.file(m.from) }
                    let sameRank = others.contains { Sq.rank($0.from) == Sq.rank(m.from) }
                    let fileChar = String(Sq.name(m.from).first!)
                    let rankChar = String(Sq.name(m.from).last!)
                    if !sameFile { s += fileChar }
                    else if !sameRank { s += rankChar }
                    else { s += fileChar + rankChar }
                }
                if isCapture { s += "x" }
            }
            s += Sq.name(m.to)
            if let p = m.promotion { s += "=" + String(p.letter) }
        }
        let next = applyingUnchecked(m)
        if next.isCheck { s += next.legalMoves().isEmpty ? "#" : "+" }
        return s
    }

    /// Parses SAN (tolerant of 0-0, annotations, "e.p.", missing x/+, and UCI-ish "e2e4") into a legal move.
    public func parseSAN(_ text: String) throws -> Move {
        var s = text.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "e.p.", with: "")
        while let l = s.last, "+#!?".contains(l) { s.removeLast() }
        s = s.replacingOccurrences(of: "0", with: "O").replacingOccurrences(of: "–", with: "-")
        let legal = legalMoves()
        if s == "O-O" || s == "O-O-O" {
            let home = turn == .white ? 4 : 60
            let to = s == "O-O" ? home + 2 : home - 2
            if let m = legal.first(where: { $0.from == home && $0.to == to && board[home]?.type == .king }) { return m }
            throw ChessError.illegalMove(text)
        }
        // Long algebraic like e2e4 / e7e8q
        if let m = Move(uci: s.lowercased()), s.count >= 4, s.first!.isLowercase,
           s.count == 4 || s.last!.isLowercase, legal.contains(m) { return m }

        var chars = Array(s)
        var promo: PieceType?
        if chars.count > 2, let last = chars.last, last.isLetter, "QRBNqrbn".contains(last), let pt = PieceType(letter: last) {
            promo = pt
            chars.removeLast()
            if chars.last == "=" { chars.removeLast() }
        }
        guard chars.count >= 2, let to = Sq.parse(String(chars.suffix(2))) else { throw ChessError.illegalMove(text) }
        chars.removeLast(2)
        if chars.last == "x" || chars.last == "-" { chars.removeLast() }
        var type = PieceType.pawn
        if let f = chars.first, f.isUppercase, let t = PieceType(letter: f) {
            type = t
            chars.removeFirst()
        }
        var fromFile: Int?, fromRank: Int?
        for c in chars {
            if let a = c.asciiValue, a >= 97, a <= 104 { fromFile = Int(a) - 97 }
            else if let a = c.asciiValue, a >= 49, a <= 56 { fromRank = Int(a) - 49 }
            else { throw ChessError.illegalMove(text) }
        }
        let cands = legal.filter { m in
            guard m.to == to, let p = board[m.from], p.type == type else { return false }
            if let ff = fromFile, Sq.file(m.from) != ff { return false }
            if let fr = fromRank, Sq.rank(m.from) != fr { return false }
            if let pr = promo { if m.promotion != pr { return false } } else if m.promotion != nil && m.promotion != .queen { return false }
            return true
        }
        // A pawn move that promotes without an explicit piece is not valid SAN, but accept queen.
        let filtered = cands
        guard let m = filtered.first else { throw ChessError.illegalMove(text) }
        if filtered.count > 1 { throw ChessError.ambiguousMove(text) }
        return m
    }
}
