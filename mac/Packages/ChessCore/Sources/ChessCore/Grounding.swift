import Foundation

/// Checks that the moves an AI answer cites come from the data it was given (the game, engine lines, tool results).
/// Language models misplace pieces and invent lines; anything not in the data is flagged.
public enum Grounding {
    /// A move cited in text: the SAN as written, and the move number before it if there was one.
    public struct Citation: Equatable, Sendable {
        public var san: String
        public var number: Int?
        public var black: Bool          // "23...Nf6" / "23…Nf6"
    }

    // Piece moves (Nf3, Raxd1, Qh4+), pawn captures (exd5, bxa8=Q), castling, and numbered pawn pushes ("12. e4", "12...e5").
    // Bare squares ("the knight on f5") are not moves, so a pawn push only counts after a move number or with =Q/+/#.
    private static let pattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9])(?:(\d{1,3})\s?(\.{3}|\u2026|\.)\s?)?("#
        + #"O-O(?:-O)?[+#]?(?![A-Za-z0-9-])|0-0(?:-0)?[+#]?(?![A-Za-z0-9-])"#
        + #"|[KQRBN][a-h]?[1-8]?x?[a-h][1-8][+#]?"#
        + #"|[a-h]x[a-h][1-8](?:=?[QRBN])?[+#]?"#
        + #"|[a-h][1-8](?:=?[QRBN])?[+#]?"#
        + #")(?![A-Za-z0-9])"#)

    /// Every move cited in `text`.
    public static func citations(in text: String) -> [Citation] {
        let ns = text as NSString
        var out: [Citation] = []
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let san = ns.substring(with: m.range(at: 3))
            let num = m.range(at: 1).location != NSNotFound ? Int(ns.substring(with: m.range(at: 1))) : nil
            let dots = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            let isPush = san.first.map { "abcdefgh".contains($0) } == true && !san.contains("x")
            // A bare square is only a move when numbered or suffixed ("e8=Q", "g6+").
            if isPush, num == nil, !san.contains(where: { "=+#QRBN".contains($0) }) { continue }
            out.append(Citation(san: san, number: num, black: dots == "..." || dots == "\u{2026}"))
        }
        return out
    }

    /// Canonical form for comparing SAN: no check/mate/annotation marks, no "x" or "=", 0-0 written O-O.
    public static func normalize(_ san: String) -> String {
        var s = san.replacingOccurrences(of: "0", with: "O")
        s.removeAll { "+#!?x=".contains($0) }
        return s
    }

    public static func allowed<S: Sequence>(_ sans: S) -> Set<String> where S.Element == String {
        Set(sans.map(normalize))
    }

    /// Moves cited in `text` that are not in `allowed` (normalized SAN), in order, without repeats.
    public static func unsupported(in text: String, allowed: Set<String>) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for c in citations(in: text) where !allowed.contains(normalize(c.san)) {
            if seen.insert(normalize(c.san)).inserted { out.append(c.san) }
        }
        return out
    }

    /// Drops the sentences of `text` that cite unsupported moves. Returns the rest and the dropped sentences.
    public static func prune(_ text: String, allowed: Set<String>) -> (text: String, dropped: [String]) {
        var kept: [String] = [], dropped: [String] = []
        for s in sentences(text) {
            if unsupported(in: s, allowed: allowed).isEmpty { kept.append(s) } else { dropped.append(s) }
        }
        return (kept.joined(separator: " "), dropped)
    }

    /// Grounds one field of an answer: sentences citing unsupported moves are dropped; if that would leave nothing,
    /// the text stays as written and the unsupported moves are returned so the UI can mark it unverified.
    public static func clean(_ text: String, allowed: Set<String>) -> (text: String, unverified: [String]) {
        let bad = unsupported(in: text, allowed: allowed)
        guard !bad.isEmpty else { return (text, []) }
        let p = prune(text, allowed: allowed)
        return p.text.isEmpty ? (text, bad) : (p.text, [])
    }

    /// Splits prose at ". ", "! " and "? " (not inside "23...Nf6" or "12. e4").
    public static func sentences(_ text: String) -> [String] {
        let chars = Array(text)
        var out: [String] = [], cur = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            cur.append(c)
            if ".!?".contains(c), i + 1 < chars.count, chars[i + 1] == " " {
                // Not after a bare move number ("12. e4") or inside an ellipsis.
                var j = i - 1
                while j >= 0, chars[j].isNumber { j -= 1 }
                let bareNumber = j < i - 1 && (j < 0 || chars[j] == " " || chars[j] == "(")
                if !bareNumber && (i == 0 || chars[i - 1] != ".") {
                    out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
                }
            }
            i += 1
        }
        let rest = cur.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// Resolves a move reference ("23...Nf6", "23. Nf3", "Nf6", "46") to a ply (1 = White's first move).
    /// `line` is the SAN of the game's moves; `firstPly` the ply of `line[0]`. A number without a move
    /// is read as a ply. Returns nil when it matches nothing in the line.
    public static func ply(of ref: String, line: [String], firstPly: Int = 1) -> Int? {
        let t = ref.trimmingCharacters(in: .whitespaces)
        if let n = Int(t) { return (firstPly..<(firstPly + line.count)).contains(n) ? n : nil }
        guard let c = citations(in: t).first ?? citations(in: "1. " + t).first.map({ Citation(san: $0.san, number: nil, black: false) })
        else { return nil }
        let want = normalize(c.san)
        let hits = line.indices.filter { normalize(line[$0]) == want }.map { $0 + firstPly }
        if let n = c.number {
            let exact = (n - 1) * 2 + (c.black ? 2 : 1)
            if hits.contains(exact) { return exact }
            // Wrong side marker: accept the move at that number for either side.
            if let h = hits.first(where: { ($0 + 1) / 2 == n }) { return h }
        }
        return hits.first
    }
}
