import Foundation

public struct PGNIssue: Sendable, Equatable, LocalizedError {
    public var moveNumber: Int
    public var isBlackMove: Bool
    public var san: String
    public var inVariation: Bool

    public var message: String {
        let dots = isBlackMove ? "\u{2026}" : "."
        return "Move \(moveNumber)\(dots) \(san) is illegal in this position"
    }
    public var errorDescription: String? { message }
}

public struct ParsedGame: Sendable {
    public var game: Game
    /// The first illegal or unreadable move, if any. `game` holds everything before it.
    public var issue: PGNIssue?
    public var title: String { PGN.title(of: game) }
}

public enum PGN {
    /// A header value worth showing: not empty, not a "?" placeholder, not a one-letter stub.
    public static func meaningful(_ v: String?) -> String? {
        guard let t = v?.trimmingCharacters(in: .whitespaces), t.count > 1, !t.allSatisfy({ $0 == "?" || $0 == "-" || $0 == "." }) else { return nil }
        return t
    }

    public static func title(of g: Game) -> String {
        let w = meaningful(g.header("White")), b = meaningful(g.header("Black"))
        if w == nil && b == nil { return meaningful(g.header("Event")) ?? "Untitled game" }
        return "\(w ?? "?") – \(b ?? "?")"
    }

    // MARK: Parsing

    public static func parse(_ text: String) -> [ParsedGame] {
        var parser = Parser(Array(text.unicodeScalars))
        return parser.parseAll()
    }

    struct Parser {
        let s: [Unicode.Scalar]
        var i = 0
        init(_ s: [Unicode.Scalar]) { self.s = s }

        enum Token { case tag(String, String), move(String), open, close, comment(String), nag(Int), result(String), number }

        mutating func skipSpace() {
            while i < s.count {
                let c = s[i]
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "\u{FEFF}" || c == "\u{A0}" { i += 1 }
                else if c == "%", i == 0 || s[i - 1] == "\n" { while i < s.count, s[i] != "\n" { i += 1 } }
                else if c == ";" { while i < s.count, s[i] != "\n" { i += 1 } }
                else { break }
            }
        }

        mutating func next() -> Token? {
            skipSpace()
            guard i < s.count else { return nil }
            let c = s[i]
            switch c {
            case "[":
                var j = i + 1
                var key = ""
                while j < s.count, s[j] != " ", s[j] != "\"", s[j] != "\u{201C}", s[j] != "]" { key.unicodeScalars.append(s[j]); j += 1 }
                while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
                var val = ""
                if j < s.count, s[j] == "\"" || s[j] == "\u{201C}" {
                    j += 1
                    while j < s.count, s[j] != "\"", s[j] != "\u{201D}" {
                        if s[j] == "\\", j + 1 < s.count { j += 1 }
                        val.unicodeScalars.append(s[j]); j += 1
                    }
                    j += 1
                }
                while j < s.count, s[j] != "]", s[j] != "\n" { j += 1 }
                if j < s.count, s[j] == "]" { j += 1 }
                i = j
                return .tag(key, val)
            case "{":
                var j = i + 1; var t = ""
                while j < s.count, s[j] != "}" { t.unicodeScalars.append(s[j]); j += 1 }
                i = min(j + 1, s.count)
                return .comment(t.trimmingCharacters(in: .whitespacesAndNewlines))
            case "(": i += 1; return .open
            case ")": i += 1; return .close
            case "$":
                var j = i + 1; var n = ""
                while j < s.count, s[j].properties.numericType != nil { n.unicodeScalars.append(s[j]); j += 1 }
                i = j
                return .nag(Int(n) ?? 0)
            default:
                var j = i; var w = ""
                while j < s.count {
                    let d = s[j]
                    if d == " " || d == "\t" || d == "\n" || d == "\r" || d == "{" || d == "}" || d == "(" || d == ")" || d == ";" || d == "$" { break }
                    w.unicodeScalars.append(d); j += 1
                }
                if j == i { i += 1; return next() }
                i = j
                return classify(w)
            }
        }

        func classify(_ w: String) -> Token {
            if ["1-0", "0-1", "1/2-1/2", "*", "½-½"].contains(w) { return .result(w == "½-½" ? "1/2-1/2" : w) }
            // Move numbers: 12. or 12... (possibly glued to a move: 12.e4)
            if let f = w.first, f.isNumber {
                var rest = Substring(w)
                while let c = rest.first, c.isNumber { rest = rest.dropFirst() }
                if rest.first == "." {
                    while rest.first == "." { rest = rest.dropFirst() }
                    return rest.isEmpty ? .number : .move(String(rest))
                }
            }
            if w.allSatisfy({ $0 == "." }) { return .number }
            return .move(w)
        }

        mutating func parseAll() -> [ParsedGame] {
            var out: [ParsedGame] = []
            while true {
                skipSpace()
                guard i < s.count else { break }
                if let g = parseGame() { out.append(g) } else { break }
            }
            return out
        }

        mutating func parseGame() -> ParsedGame? {
            var headers: [(key: String, value: String)] = []
            var tokens: [Token] = []
            var sawMove = false
            // Collect tokens up to and including the result token.
            while true {
                let save = i
                guard let t = next() else { break }
                if case .tag(let k, let v) = t {
                    if sawMove { i = save; break }     // next game begins
                    headers.append((k, v)); continue
                }
                if case .number = t { continue }
                if case .move = t { sawMove = true }
                tokens.append(t)
                if case .result = t { break }
            }
            if headers.isEmpty && tokens.isEmpty { return nil }
            return build(headers: headers, tokens: tokens)
        }

        func build(headers: [(key: String, value: String)], tokens: [Token]) -> ParsedGame {
            var start = Position.start
            if let fen = headers.first(where: { $0.key == "FEN" })?.value, let p = try? Position(fen: fen) { start = p }
            var game = Game(startPosition: start, headers: headers.filter { $0.key != "SetUp" && $0.key != "FEN" })
            var issue: PGNIssue?
            var cur = 0
            var stack: [(cur: Int, prev: Int, dead: Bool)] = []
            var prev = 0
            var dead = false      // ignoring tokens in the current line after an illegal move
            for t in tokens {
                switch t {
                case .move(let san):
                    if dead { continue }
                    if san == "--" || san == "Z0" { dead = true; continue }
                    let pos = game.nodes[cur].position
                    do {
                        let m = try pos.parseSAN(san)
                        let id = try game.addMove(m, after: cur)
                        prev = cur; cur = id
                        var suffix = ""
                        for ch in san.reversed() { if ch == "!" || ch == "?" { suffix = String(ch) + suffix } else if ch == "+" || ch == "#" { continue } else { break } }
                        if let nag = ["!": 1, "?": 2, "!!": 3, "??": 4, "!?": 5, "?!": 6][suffix], !game.nodes[id].nags.contains(nag) { game.nodes[id].nags.append(nag) }
                    } catch {
                        let clean = san.trimmingCharacters(in: CharacterSet(charactersIn: "!?"))
                        if issue == nil {
                            issue = PGNIssue(moveNumber: pos.fullmove, isBlackMove: pos.turn == .black, san: clean, inVariation: !stack.isEmpty)
                        }
                        dead = true
                    }
                case .open:
                    stack.append((cur, prev, dead))
                    if !dead { if cur == 0 { dead = true } else { cur = prev } }
                case .close:
                    if let top = stack.popLast() { cur = top.cur; prev = top.prev; dead = top.dead }
                case .comment(let c):
                    if dead { continue }
                    let existing = game.nodes[cur].comment
                    game.nodes[cur].comment = existing.map { $0 + " " + c } ?? c
                case .nag(let n):
                    if !dead, cur != 0 { game.nodes[cur].nags.append(n) }
                case .result(let r):
                    if stack.isEmpty { game.result = r }
                default:
                    break
                }
            }
            if game.result == "*", let r = headers.first(where: { $0.key == "Result" })?.value, r != "*" { game.result = r }
            if game.header("Result") == nil { game.setHeader("Result", game.result) }
            return ParsedGame(game: game, issue: issue)
        }
    }

    // MARK: Export

    private static let nagSymbols: [Int: String] = [1: "!", 2: "?", 3: "!!", 4: "??", 5: "!?", 6: "?!"]

    public static func nagText(_ n: Int) -> String { nagSymbols[n] ?? "$\(n)" }

    /// The `[%eval ...]` command in a comment, White's point of view: `0.23` is pawns, `#3` / `#-2` is mate. An optional `,depth` is ignored.
    public static func evalAnnotation(_ comment: String) -> Eval? {
        guard let r = comment.range(of: #"\[%eval\s+([^\]\s,]+)[^\]]*\]"#, options: .regularExpression) else { return nil }
        let inner = comment[r].dropFirst(6).drop { $0 == " " || $0 == "\t" || $0 == "\n" }.prefix { $0 != "]" && $0 != "," && !$0.isWhitespace }
        if inner.hasPrefix("#") {
            guard let m = Int(inner.dropFirst().replacingOccurrences(of: "+", with: "")), m != 0 else { return nil }
            return .mate(m)
        }
        guard let v = Double(inner), v.isFinite else { return nil }
        return .cp(Int((v * 100).rounded()))
    }

    /// Exports a game as PGN (with variations and comments).
    public static func export(_ g: Game, includeHeaders: Bool = true) -> String {
        var out = ""
        if includeHeaders {
            let roster = ["Event", "Site", "Date", "Round", "White", "Black"]
            for k in roster {
                let v = g.header(k) ?? (k == "Date" ? "????.??.??" : "?")
                out += "[\(k) \"\(escape(v))\"]\n"
            }
            out += "[Result \"\(g.result)\"]\n"
            for (k, v) in g.headers where !roster.contains(k) && k != "Result" {
                out += "[\(k) \"\(escape(v))\"]\n"
            }
            out += "\n"
        }
        var tokens: [String] = []
        if let c = g.nodes[0].comment { tokens.append("{\(sanitize(c))}") }
        writeLine(g, from: 0, forceNumber: true, into: &tokens)
        tokens.append(g.result)
        out += wrap(tokens)
        return out + "\n"
    }

    private static func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
    private static func sanitize(_ s: String) -> String { s.replacingOccurrences(of: "}", with: ")") }

    private static func label(_ pos: Position, _ n: GameNode, number: Bool) -> String {
        var t = ""
        if pos.turn == .white { t = "\(pos.fullmove). " } else if number { t = "\(pos.fullmove)... " }
        return t + n.san + n.nags.map { " $\($0)" }.joined()
    }

    private static func writeLine(_ g: Game, from node: Int, forceNumber: Bool, into out: inout [String]) {
        var cur = node
        var needNumber = forceNumber
        while let first = g.nodes[cur].children.first {
            let pos = g.nodes[cur].position
            let kids = g.nodes[cur].children
            out.append(label(pos, g.nodes[first], number: needNumber))
            if let c = g.nodes[first].comment { out.append("{\(sanitize(c))}") }
            for alt in kids.dropFirst() {
                var sub = [label(pos, g.nodes[alt], number: true)]
                if let c = g.nodes[alt].comment { sub.append("{\(sanitize(c))}") }
                writeLine(g, from: alt, forceNumber: g.nodes[alt].comment != nil, into: &sub)
                out.append("(" + sub.joined(separator: " ") + ")")
            }
            needNumber = g.nodes[first].comment != nil || kids.count > 1
            cur = first
        }
    }

    private static func wrap(_ tokens: [String], width: Int = 80) -> String {
        var lines: [String] = []; var line = ""
        for t in tokens {
            if line.isEmpty { line = t }
            else if line.count + 1 + t.count > width { lines.append(line); line = t }
            else { line += " " + t }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }
}
