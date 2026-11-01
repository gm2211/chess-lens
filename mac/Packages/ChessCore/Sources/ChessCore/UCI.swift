import Foundation

/// An engine score from White's point of view.
public enum Eval: Sendable, Equatable, Hashable {
    case cp(Int)
    case mate(Int)          // positive: White mates in n; negative: Black mates in |n|
    case checkmate(winner: Side)   // the game is over: the other side has been mated

    /// Centipawns for charting: mate scores are clamped to a large value.
    public var centipawns: Int {
        switch self {
        case .cp(let c): return max(-3000, min(3000, c))
        case .mate(let m): return m > 0 ? 3000 - min(m, 50) : -3000 + min(-m, 50)
        case .checkmate(let w): return w == .white ? 3000 : -3000
        }
    }

    /// Win probability for White in 0...100 (lichess-style logistic).
    public var whiteWinPercent: Double {
        switch self {
        case .mate(let m): return m > 0 ? 100 : (m < 0 ? 0 : 50)
        case .checkmate(let w): return w == .white ? 100 : 0
        case .cp(let c): return 50 + 50 * (2 / (1 + exp(-0.00368208 * Double(c))) - 1)
        }
    }

    /// "+0.35", "-1.20", "M3", "-M5".
    public var display: String {
        switch self {
        case .mate(let m): return m < 0 ? "-M\(abs(m))" : "M\(m)"
        case .checkmate(let w): return w == .white ? "1-0" : "0-1"
        case .cp(let c):
            let v = Double(c) / 100
            return (c > 0 ? "+" : "") + String(format: "%.2f", v)
        }
    }

    /// Short signed form for the eval bar, always from White's view: "+0.4", "\u{2212}1.2", "0.0", "M3", "\u{2212}M3".
    public var barLabel: String {
        switch self {
        case .mate(let m): return m < 0 ? "\u{2212}M\(abs(m))" : "M\(m)"
        case .checkmate(let w): return w == .white ? "1-0" : "0-1"
        case .cp(let c):
            let v = abs(Double(c) / 100)
            let body = v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
            if body == "0.0" { return body }
            return (c > 0 ? "+" : "\u{2212}") + body
        }
    }

    /// Plain-language reading of the score, for tooltips.
    public var plainDescription: String {
        switch self {
        case .mate(let m):
            if m == 0 { return "Equal" }
            return m > 0 ? "White mates in \(m)" : "Black mates in \(-m)"
        case .checkmate(let w): return w == .white ? "White has won by checkmate" : "Black has won by checkmate"
        case .cp(let c):
            let v = abs(Double(c) / 100)
            let t = v >= 10 ? String(format: "%.0f", v) : String(format: "%.1f", v)
            if t == "0.0" { return "Equal" }
            return (c > 0 ? "White" : "Black") + " is better by \(t) pawns"
        }
    }
}

public struct UCIInfo: Sendable, Equatable {
    public var depth: Int = 0
    public var seldepth: Int?
    public var multipv: Int = 1
    public var scoreCp: Int?          // from the side to move's perspective
    public var scoreMate: Int?        // from the side to move's perspective
    public var isBound: Bool = false  // lowerbound / upperbound
    public var nodes: Int?
    public var nps: Int?
    public var timeMs: Int?
    public var pv: [String] = []

    public init() {}

    public var hasScore: Bool { scoreCp != nil || scoreMate != nil }

    /// Normalises the side-to-move score to White's perspective.
    public func eval(whiteToMove: Bool) -> Eval? {
        let sign = whiteToMove ? 1 : -1
        if let m = scoreMate { return .mate(m * sign) }
        if let c = scoreCp { return .cp(c * sign) }
        return nil
    }
}

public enum UCI {
    /// Parses an `info ...` line. Returns nil for lines without depth/score/pv content (e.g. `info string`, `info currmove`).
    public static func parseInfo(_ line: String) -> UCIInfo? {
        let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard t.first == "info", t.count > 1, t[1] != "string" else { return nil }
        var info = UCIInfo()
        var sawContent = false
        var i = 1
        func int(_ j: Int) -> Int? { j < t.count ? Int(t[j]) : nil }
        while i < t.count {
            switch t[i] {
            case "depth": if let v = int(i + 1) { info.depth = v; sawContent = true }; i += 2
            case "seldepth": info.seldepth = int(i + 1); i += 2
            case "multipv": if let v = int(i + 1) { info.multipv = v }; i += 2
            case "score":
                var j = i + 1
                if j < t.count, t[j] == "cp" { info.scoreCp = int(j + 1); j += 2; sawContent = true }
                else if j < t.count, t[j] == "mate" { info.scoreMate = int(j + 1); j += 2; sawContent = true }
                while j < t.count, t[j] == "lowerbound" || t[j] == "upperbound" { info.isBound = true; j += 1 }
                i = j
            case "nodes": info.nodes = int(i + 1); i += 2
            case "nps": info.nps = int(i + 1); i += 2
            case "time": info.timeMs = int(i + 1); i += 2
            case "hashfull", "tbhits", "currmovenumber", "cpuload": i += 2
            case "currmove": return nil
            case "pv":
                info.pv = Array(t[(i + 1)...])
                i = t.count
            default: i += 1
            }
        }
        return sawContent ? info : nil
    }

    /// Parses `bestmove e2e4 ponder e7e5`. Returns (nil, nil) for `bestmove (none)`.
    public static func parseBestMove(_ line: String) -> (best: String?, ponder: String?)? {
        let t = line.split(separator: " ").map(String.init)
        guard t.first == "bestmove", t.count >= 2 else { return nil }
        let best = t[1] == "(none)" || t[1] == "0000" ? nil : t[1]
        var ponder: String?
        if let i = t.firstIndex(of: "ponder"), i + 1 < t.count { ponder = t[i + 1] }
        return (best, ponder)
    }
}

extension Position {
    /// Converts a UCI principal variation to SAN, stopping at the first move that is not legal.
    public func sanLine(fromUCI pv: [String], maxPlies: Int = 40) -> [String] {
        var pos = self
        var out: [String] = []
        for u in pv.prefix(maxPlies) {
            guard let m = Move(uci: u), pos.isLegal(m) else { break }
            out.append(pos.san(m))
            pos = pos.applyingUnchecked(m)
        }
        return out
    }

    /// Like `sanLine`, but formatted with move numbers: "12. Nf3 Nc6 13. Bb5".
    public func numberedLine(fromUCI pv: [String], maxPlies: Int = 12) -> String {
        let sans = sanLine(fromUCI: pv, maxPlies: maxPlies)
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

    /// Resolves a UCI move string to a legal `Move`.
    public func move(fromUCI s: String) -> Move? {
        guard let m = Move(uci: s), isLegal(m) else { return nil }
        return m
    }
}
