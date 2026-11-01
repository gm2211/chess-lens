import Foundation

/// "Find a better move": judges the move the player tries at a review's error against the engine's best.
/// The best move's eval comes from the review; the tried move is evaluated by the engine on its own.
public enum BetterMove {
    /// A try is accepted when it gives up at most this many win-% points against the engine's best.
    public static let acceptLoss = 5.0
    /// Above this loss a wrong try is "clearly worse", above `losingLoss` it "falls apart".
    public static let clearLoss = 10.0
    public static let losingLoss = 20.0

    public enum Verdict: Equatable, Sendable {
        /// The engine's own first choice.
        case top
        /// Within `acceptLoss` of the best.
        case good
        /// The move played in the game again.
        case gameMove
        /// Worse than the best by `loss` win-% points; `reply` is the engine's answer, for display ("10. Nxb5").
        case notQuite(reply: String?, loss: Double)
        /// The engine couldn't evaluate the try.
        case unchecked

        public var isCorrect: Bool { self == .top || self == .good }
    }

    /// - Parameters:
    ///   - tried, best, played: UCI moves from the quiz position.
    ///   - bestEval: the position's eval with best play (White's view), from the review.
    ///   - triedEval: the eval after the tried move (White's view), nil if the engine gave none.
    ///   - reply: the engine's answer to the tried move, already formatted for display.
    public static func judge(tried: String, side: Side, best: String?, bestEval: Eval, played: String,
                             triedEval: Eval?, reply: String? = nil) -> Verdict {
        let t = tried.lowercased()
        if let best, t == best.lowercased() { return .top }
        if t == played.lowercased() { return .gameMove }
        guard let triedEval else { return .unchecked }
        let l = loss(side: side, bestEval: bestEval, triedEval: triedEval)
        return l <= acceptLoss ? .good : .notQuite(reply: reply, loss: l)
    }

    /// Win-% points `side` gives up with the try, never negative.
    public static func loss(side: Side, bestEval: Eval, triedEval: Eval) -> Double {
        func win(_ e: Eval) -> Double { side == .white ? e.whiteWinPercent : 100 - e.whiteWinPercent }
        return max(0, win(bestEval) - win(triedEval))
    }

    /// The question on the beat card.
    public static func prompt(side: Side) -> String { "Find a better move for \(side == .white ? "White" : "Black")" }

    /// The feedback line for a verdict.
    public static func text(_ v: Verdict) -> String {
        switch v {
        case .top: return "Excellent \u{2014} that's the engine's top choice."
        case .good: return "Good \u{2014} also fine."
        case .gameMove: return "That's the move from the game. Look for something better."
        case .unchecked: return "The engine couldn't check that move. Try again, or ask to be shown."
        case .notQuite(let reply, let loss):
            let outcome = loss > losingLoss ? "the position falls apart" : loss > clearLoss ? "it's clearly worse" : "it's a little worse than the best move"
            if let reply { return "Not quite \u{2014} after \(reply), \(outcome)." }
            return "Not quite \u{2014} \(outcome)."
        }
    }
}
