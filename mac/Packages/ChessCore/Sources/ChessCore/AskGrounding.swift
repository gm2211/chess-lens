import Foundation

/// Facts computed in code for "Ask AI" so the model never has to count material or judge an evaluation itself.

/// Piece counts and point totals (P1 N3 B3 R5 Q9) for both sides.
public struct MaterialSummary: Equatable, Sendable {
    public var white: [PieceType: Int]
    public var black: [PieceType: Int]
    public var whitePoints: Int
    public var blackPoints: Int
    /// White minus Black, in points.
    public var difference: Int { whitePoints - blackPoints }

    static let order: [PieceType] = [.queen, .rook, .bishop, .knight, .pawn]
    static func value(_ t: PieceType) -> Int {
        switch t { case .pawn: 1; case .knight, .bishop: 3; case .rook: 5; case .queen: 9; case .king: 0 }
    }

    init(_ p: Position) {
        var w: [PieceType: Int] = [:], b: [PieceType: Int] = [:]
        for sq in 0..<64 {
            guard let pc = p.piece(at: sq), pc.type != .king else { continue }
            if pc.color == .white { w[pc.type, default: 0] += 1 } else { b[pc.type, default: 0] += 1 }
        }
        white = w; black = b
        whitePoints = w.reduce(0) { $0 + $1.value * Self.value($1.key) }
        blackPoints = b.reduce(0) { $0 + $1.value * Self.value($1.key) }
    }

    private static let names: [PieceType: (String, String)] =
        [.queen: ("queen", "queens"), .rook: ("rook", "rooks"), .bishop: ("bishop", "bishops"),
         .knight: ("knight", "knights"), .pawn: ("pawn", "pawns")]
    private static let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

    private func inventory(_ c: [PieceType: Int]) -> String {
        let parts = Self.order.compactMap { t -> String? in
            guard let n = c[t], n > 0 else { return nil }
            return "\(n) \(n == 1 ? Self.names[t]!.0 : Self.names[t]!.1)"
        }
        return parts.isEmpty ? "no pieces besides the king" : parts.joined(separator: ", ")
    }

    /// "a rook", "two pawns", "a queen and a pawn".
    private func phrase(_ c: [PieceType: Int]) -> String {
        let parts = Self.order.compactMap { t -> String? in
            guard let n = c[t], n > 0 else { return nil }
            if n == 1 { return "\(["a", "e", "i", "o", "u"].contains(String(Self.names[t]!.0.first!)) ? "an" : "a") \(Self.names[t]!.0)" }
            return "\(n < Self.words.count ? Self.words[n] : String(n)) \(Self.names[t]!.1)"
        }
        return parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : (parts.first ?? "nothing")
    }

    /// "White is up a rook for a pawn (+4 points)." / "Material is equal."
    public var sentence: String {
        let extraW = Self.order.reduce(into: [PieceType: Int]()) { r, t in
            let d = (white[t] ?? 0) - (black[t] ?? 0); if d > 0 { r[t] = d }
        }
        let extraB = Self.order.reduce(into: [PieceType: Int]()) { r, t in
            let d = (black[t] ?? 0) - (white[t] ?? 0); if d > 0 { r[t] = d }
        }
        if extraW.isEmpty && extraB.isEmpty { return "Material is equal." }
        let d = difference
        if d == 0 {
            return "Material is level in points (0), but the pieces differ: White has \(phrase(extraW)) where Black has \(phrase(extraB))."
        }
        let (lead, up, down) = d > 0 ? ("White", extraW, extraB) : ("Black", extraB, extraW)
        let pts = "(+\(abs(d)) point\(abs(d) == 1 ? "" : "s"))"
        // Strictly more material in points, so "up X" even when the other side holds extras of a different kind.
        if down.isEmpty { return "\(lead) is up \(phrase(up)) \(pts)." }
        return "\(lead) is up \(phrase(up)) for \(phrase(down)) \(pts)."
    }

    /// Two lines for the prompt's data block.
    public var promptText: String {
        "White: \(inventory(white)) = \(whitePoints) points. Black: \(inventory(black)) = \(blackPoints) points. \(sentence)"
    }
}

extension Position {
    /// Piece counts and point totals for both sides (kings excluded).
    public var materialSummary: MaterialSummary { MaterialSummary(self) }
}

/// Plain-words verdict on an evaluation (White's point of view).
public enum EngineVerdict {
    public enum Band: Equatable, Sendable { case winning, clearlyBetter, slightlyBetter, equal }

    /// The band and the side it favors (nil when equal).
    public static func band(_ e: Eval) -> (band: Band, side: Side?) {
        switch e {
        case .mate(let m): return (.winning, m > 0 ? .white : .black)
        case .checkmate(let w): return (.winning, w)
        case .cp(let c):
            let side: Side = c >= 0 ? .white : .black
            switch abs(c) {
            case 300...: return (.winning, side)
            case 150..<300: return (.clearlyBetter, side)
            case 50..<150: return (.slightlyBetter, side)
            default: return (.equal, nil)
            }
        }
    }

    private static func name(_ s: Side) -> String { s == .white ? "White" : "Black" }

    /// "White is winning", "Black is clearly better", "White mates in 3", "The position is about equal".
    public static func describe(_ e: Eval) -> String {
        if case .mate(let m) = e { return "\(m > 0 ? "White" : "Black") mates in \(abs(m))" }
        if case .checkmate(let w) = e { return "\(name(w)) has won by checkmate" }
        let (b, s) = band(e)
        guard let s else { return "The position is about equal" }
        switch b {
        case .winning: return "\(name(s)) is winning"
        case .clearlyBetter: return "\(name(s)) is clearly better"
        default: return "\(name(s)) is a bit better"
        }
    }

    /// "+5.75 for White (White's point of view): White is winning."
    public static func line(_ e: Eval) -> String { "\(e.display) from White's point of view: \(describe(e))." }
}

/// Catches answers that contradict the engine's verdict (a cheap pattern check, not a judge of the whole text).
public enum AnswerCheck {
    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }

    private static let equalClaims = [
        rx(#"\b(roughly|about|more or less|fairly|pretty|basically|nearly|almost|essentially|dynamically|materially)\s+(equal|level|even|balanced)\b"#),
        rx(#"\b(position|game|material|evaluation|chances|it)\s+(is|are|looks|remains|seems)\s+(equal|level|even|balanced|roughly)\b"#),
        rx(#"\b(dead|completely|totally) (equal|level|even)\b"#),
        rx(#"\bbalanced\b"#),
        rx(#"\bequal chances\b"#),
    ]
    private static let notLostClaims = [
        rx(#"\b(isn't|is not|isnt|not|hardly|far from)\s+(yet\s+)?(lost|over|winning|decided)\b"#),
        rx(#"\bno,?\s+(the game|it|black|white)\s+(isn't|is not)\s+lost\b"#),
        rx(#"\bstill (alive|in the game|fighting|holds? chances)\b"#),
    ]

    /// The engine's verdict (as words) when `answer` says something clearly incompatible with it; otherwise nil.
    /// Only fires when the evaluation is decisive enough for the claim to be plainly wrong:
    /// "equal"-type claims at |eval| >= 1.5, "not lost" at >= 3.0 (or mate), "the other side is better" at >= 0.5,
    /// and "X is winning" at |eval| < 1.0.
    public static func contradiction(answer: String, eval: Eval) -> String? {
        let (band, side) = EngineVerdict.band(eval)
        let verdict = EngineVerdict.describe(eval)
        let ns = answer as NSString
        let all = NSRange(location: 0, length: ns.length)
        func hit(_ rs: [NSRegularExpression]) -> Bool { rs.contains { $0.firstMatch(in: answer, range: all) != nil } }
        func word(_ s: Side) -> String { s == .white ? "white" : "black" }

        if let side {
            let loser = side == .white ? Side.black : Side.white
            let l = word(loser), w = word(side)
            if band == .winning || band == .clearlyBetter, hit(equalClaims) { return verdict }
            if band == .winning, hit(notLostClaims) { return verdict }
            // "Black is better / slightly better / ahead", "better for Black", "good for Black" when the other side leads.
            let loserBetter = [
                rx(#"\b\#(l)\s+(is|looks|seems|stands|remains)\s+(\w+\s+){0,2}(better|ahead|winning|up)\b"#),
                rx(#"\b(better|ahead|advantage|edge|winning|favou?rable|good)\s+for\s+\#(l)\b"#),
                rx(#"\b\#(l)\s+(has|holds|gets)\s+(\w+\s+){0,2}(edge|advantage|initiative)\b"#),
            ]
            // The sentence must not also state the real leader as ahead ("White is better, not Black").
            for sentence in Grounding.sentences(answer) {
                let sn = sentence as NSString
                let r = NSRange(location: 0, length: sn.length)
                if loserBetter.contains(where: { $0.firstMatch(in: sentence, range: r) != nil }),
                   !sentence.lowercased().contains("\(w) is") , !sentence.lowercased().contains("not \(l)") {
                    return verdict
                }
            }
        } else {
            // About equal: claims that someone is winning outright.
            let claim = rx(#"\b(white|black)\s+(is|looks|seems)\s+(\w+\s+){0,1}(winning|lost|crushing|totally lost|completely lost)\b"#)
            if claim.firstMatch(in: answer, range: all) != nil { return verdict }
        }
        if band == .slightlyBetter, let side {
            let w = word(side)
            let claim = rx(#"\b\#(w == "white" ? "black" : "white")\s+(is|looks|seems)\s+(\w+\s+){0,1}(winning|lost|completely lost|totally lost)\b"#)
            if claim.firstMatch(in: answer, range: all) != nil { return verdict }
        }
        return nil
    }

    /// The note appended to the prompt for the one automatic retry.
    public static func correctiveNote(verdict: String) -> String {
        "Your previous answer contradicted the engine: \(verdict). Answer again consistent with the data."
    }
}
