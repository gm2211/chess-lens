import Foundation

/// A text protocol that lets any language model ask Stockfish about a position while it writes.
/// The model answers with only `<engine fen="FEN" moves="Nf3 d5"/>`; the app runs the engine and re-sends the
/// conversation with the result appended (providers here are single-turn, so the transcript lives in the prompt).
public struct EngineToolRequest: Equatable, Sendable {
    public var fen: String
    public var moves: [String]
    public init(fen: String, moves: [String] = []) { self.fen = fen; self.moves = moves }

    /// The tag as the model would write it.
    public var tag: String {
        "<engine fen=\"\(fen)\"" + (moves.isEmpty ? "" : " moves=\"\(moves.joined(separator: " "))\"") + "/>"
    }
}

/// One line of an engine answer: score from White's point of view and the UCI moves.
public struct EngineToolLine: Equatable, Sendable {
    public var eval: Eval
    public var pv: [String]
    public init(eval: Eval, pv: [String]) { self.eval = eval; self.pv = pv }
}

public enum EngineTool {
    public static let maxCalls = 4
    /// Plies of each returned line.
    public static let linePlies = 8

    /// Tool description for the system prompt.
    public static let instructions = """
    Engine tool: before writing, you may check an idea with Stockfish. To do so, reply with ONLY one line \
    <engine fen="FEN" moves="SAN SAN"/> where FEN is a position from the data and moves (optional) are legal SAN \
    moves played from it. You get the evaluation and the top 3 lines, then continue. Use it at most \(maxCalls) times, \
    only when the data doesn't already answer your question. Your final answer must not contain the tag.
    """

    private static let tagPattern = try! NSRegularExpression(pattern: #"<engine\b([^<>]*?)/?>"#, options: [.caseInsensitive])
    private static let attrPattern = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)

    /// Engine requests in a model reply, in order. Empty when the reply is a final answer.
    public static func requests(in text: String) -> [EngineToolRequest] {
        let ns = text as NSString
        return tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let attrs = ns.substring(with: m.range(at: 1))
            let ans = attrs as NSString
            var fen: String?, moves: [String] = []
            for a in attrPattern.matches(in: attrs, range: NSRange(location: 0, length: ans.length)) {
                let key = ans.substring(with: a.range(at: 1)).lowercased()
                let r = a.range(at: 2).location != NSNotFound ? a.range(at: 2) : a.range(at: 3)
                let val = ans.substring(with: r).trimmingCharacters(in: .whitespaces)
                if key == "fen" { fen = val }
                if key == "moves" { moves = sanTokens(val) }
            }
            return fen.map { EngineToolRequest(fen: $0, moves: moves) }
        }
    }

    /// True once `text` holds a complete tag, so streaming can stop early.
    public static func hasCompleteRequest(_ text: String) -> Bool {
        guard let r = text.range(of: "<engine", options: .caseInsensitive) else { return false }
        return text[r.upperBound...].contains(">")
    }

    /// Splits "23...Nf6 24. Qd2 Bxd2" into SAN, dropping move numbers and results.
    static func sanTokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { raw in
            var t = String(raw)
            // "24.Qd2" / "23...Nf6" / "23…Nf6"
            if let r = t.range(of: #"^\d+(\.{1,3}|…)"#, options: .regularExpression) { t.removeSubrange(r) }
            if t.isEmpty || ["1-0", "0-1", "1/2-1/2", "*"].contains(t) { return nil }
            return t
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case badFEN(String)
        case illegal(String, fen: String)

        /// What the model is told.
        public var message: String {
            switch self {
            case .badFEN(let f): "Engine error: \"\(f)\" is not a valid FEN. Copy a FEN exactly from the data."
            case .illegal(let m, let f): "Engine error: \(m) is not a legal move in \(f). Moves must be SAN, played in order from the FEN."
            }
        }
    }

    /// The position to analyse (after the requested moves) and the moves in proper SAN.
    public static func resolve(_ r: EngineToolRequest) -> Result<(position: Position, sans: [String]), Failure> {
        guard var pos = try? Position(fen: r.fen), (try? pos.validate()) != nil else { return .failure(.badFEN(r.fen)) }
        var sans: [String] = []
        for m in r.moves {
            guard let mv = try? pos.parseSAN(m) else { return .failure(.illegal(m, fen: pos.fen)) }
            sans.append(pos.san(mv))
            pos = pos.applyingUnchecked(mv)
        }
        return .success((pos, sans))
    }

    /// The engine's answer for the model, plus every SAN move it shows (for grounding).
    /// `start` is the requested FEN's position, `sans` the requested moves; `position` is where the lines start.
    public static func result(for r: EngineToolRequest, start: Position, sans: [String], position: Position,
                              lines: [EngineToolLine], depth: Int) -> (text: String, sans: [String]) {
        var out: [String] = []
        var cited = sans
        let after = sans.isEmpty ? "" : " after \(start.numbered(sans))"
        let mover = position.turn == .white ? "White" : "Black"
        if position.legalMoves().isEmpty {
            out.append("Position\(after): " + (position.isCheck ? "checkmate, \(position.turn == .white ? "Black" : "White") has won." : "stalemate, a draw."))
            return (out.joined(separator: "\n"), cited)
        }
        out.append("Stockfish, depth \(depth)\(after). \(mover) to move. FEN: \(position.fen)")
        if lines.isEmpty { out.append("No lines found."); return (out.joined(separator: "\n"), cited) }
        for (i, l) in lines.prefix(3).enumerated() {
            let s = position.sanLine(fromUCI: l.pv, maxPlies: linePlies)
            cited += s
            let line = position.numberedLine(fromUCI: l.pv, maxPlies: linePlies)
            out.append("\(i + 1)) \(moverPOV(l.eval, position.turn)) for \(mover), the side to move (White's view: \(whitePOV(l.eval))): \(line)")
        }
        return (out.joined(separator: "\n"), cited)
    }

    /// Score for the side to move: "+0.35", "mates in 3", "gets mated in 3".
    static func moverPOV(_ e: Eval, _ side: Side) -> String {
        switch e {
        case .cp(let c): Eval.cp(side == .white ? c : -c).display
        case .mate(let m): (side == .white) == (m > 0) ? "mates in \(abs(m))" : "gets mated in \(abs(m))"
        case .checkmate(let w): w == side ? "has mated" : "is mated"
        }
    }

    static func whitePOV(_ e: Eval) -> String {
        switch e {
        case .cp: e.display
        case .mate(let m): m > 0 ? "White mates in \(m)" : "Black mates in \(-m)"
        case .checkmate(let w): w == .white ? "White has mated" : "Black has mated"
        }
    }

    /// One exchange in the tool loop: what the model wrote and what the engine (or an error) replied.
    public struct Turn: Equatable, Sendable {
        public var request: String
        public var reply: String
        public init(request: String, reply: String) { self.request = request; self.reply = reply }
    }

    /// The prompt for the next round: the original prompt plus the exchanges so far.
    /// With `callsLeft == 0` the model is told to answer without the tool.
    public static func transcript(prompt: String, turns: [Turn], callsLeft: Int, note: String? = nil) -> String {
        var out = prompt
        if !turns.isEmpty {
            out += "\n\n--- Engine results so far ---"
            for t in turns { out += "\nYou asked: \(t.request)\n\(t.reply)" }
            out += "\n--- End of engine results ---\n"
            out += callsLeft > 0
                ? "Ask for another position (\(callsLeft) left) or give your final answer now."
                : "No engine calls left. Give your final answer now, without the tag."
        }
        if let note { out += "\n\n" + note }
        return out
    }
}

extension Position {
    /// "23...Nf6 24. Qd2" for SAN moves played from this position.
    public func numbered(_ sans: [String]) -> String {
        var parts: [String] = []
        var number = fullmove
        var white = turn == .white
        for (i, s) in sans.enumerated() {
            if white { parts.append("\(number).") } else if i == 0 { parts.append("\(number)\u{2026}") }
            parts.append(s)
            if !white { number += 1 }
            white.toggle()
        }
        return parts.joined(separator: " ")
    }
}
