import Foundation
import Observation
import ChessCore

/// The guided review: walks the game's story beats on the main board. A beat at one of the review's errors starts
/// as a question ("Find a better move for Black") on the position before the error; the player's try is shown as a
/// preview (never added to the game) and judged by the engine (see `BetterMove`). Owned by `AppModel.walkthrough`;
/// see AppModel+Beats.
@Observable @MainActor
final class BeatWalkthrough {
    /// A beat with the game node it shows and, at an error, its question.
    struct Step: Equatable {
        var beat: GameLesson.Beat
        /// The position after the beat's move.
        var nodeID: Int
        var quiz: Quiz?
    }

    /// Everything needed to ask and judge "find a better move" at an error.
    struct Quiz: Equatable {
        var parentID: Int           // the position before the error: the question
        var side: Side
        var best: String            // UCI, the review's best move there
        var bestEval: Eval          // White's view, the review's eval of that position
        var bestLine: [String]      // the review's line from there
        var played: String          // UCI, the move played in the game
        var refutation: [String]    // the review's line after the move played
    }

    enum Phase: Equatable {
        /// Waiting for the player's move.
        case asking
        case judging(Move)
        case verdict(BetterMove.Verdict, tried: Move, reply: String?)
        /// The answer is shown ("Show me", or played through): first the best move on the question position
        /// (`onAnswer`), then the game's move and its punishment.
        case shown(onAnswer: Bool)
        /// A beat without a question, on its own position.
        case explained
    }

    let steps: [Step]
    private(set) var index = 0
    private(set) var phase: Phase = .explained
    private(set) var isPlaying = false
    private(set) var isSpeaking = false
    /// Bumps each time a beat (re)starts, so the board can animate its circles in.
    private(set) var epoch = 0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var judgeTask: Task<Void, Never>?
    @ObservationIgnored private var travelTask: Task<Void, Never>?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private let narrator: any Narrator = VoiceNarrator()
    /// The node the walkthrough put on the board; any other navigation closes it (see `AppModel.currentID`).
    @ObservationIgnored private(set) var nodeID: Int
    static let secondsPerHop = 0.35
    static let answerHold = 1.8

    init(steps: [Step], app: AppModel) {
        self.steps = steps; self.app = app
        nodeID = steps.first.map { $0.quiz?.parentID ?? $0.nodeID } ?? 0
    }

    var current: Step { steps[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < steps.count - 1 }

    /// The question is open: a move on the board is a try.
    var acceptsMove: Bool {
        guard let q = current.quiz, app?.currentID == q.parentID, travelTask == nil else { return false }
        switch phase {
        case .asking: return true
        case .verdict(let v, _, _): return !v.isCorrect
        default: return false
        }
    }

    /// The answer must stay hidden: no engine lines or arrows while the question is open.
    var hidesEngine: Bool {
        switch phase {
        case .asking, .judging: true
        case .verdict(let v, _, _): !v.isCorrect
        default: false
        }
    }

    /// Whether the beat's explanation and rule are shown (the answer is out, or there was no question).
    var isRevealed: Bool {
        switch phase {
        case .shown, .explained: true
        case .verdict(let v, _, _): v.isCorrect
        default: false
        }
    }

    /// The player's try, shown on the board on top of the question position.
    var preview: LessonPlayer.Preview? {
        guard let app, let q = current.quiz, app.game.nodes.indices.contains(q.parentID) else { return nil }
        let tried: Move
        switch phase {
        case .judging(let m): tried = m
        case .verdict(_, let m, _): tried = m
        default: return nil
        }
        let pos = app.game.nodes[q.parentID].position
        guard let next = try? pos.applying(tried) else { return nil }
        return LessonPlayer.Preview(pieces: PieceLayout.applying(tried, before: pos, to: app.pieces(for: q.parentID)),
                                    position: next, lastMove: tried)
    }

    /// Arrows (kinds as the board draws them) and circles for the beat's current phase.
    var marks: (arrows: [BoardArrow], circles: [Square]) {
        let step = current
        func arrow(_ u: String?, _ kind: BoardArrow.Kind) -> BoardArrow? {
            guard let u, let m = Move(uci: u) else { return nil }
            return BoardArrow(from: m.from, to: m.to, kind: kind, opacity: 0.85)
        }
        let beatArrows = step.beat.arrows.map { BoardArrow(from: $0.from, to: $0.to, kind: .lesson, opacity: 0.82) }
        switch phase {
        case .asking, .judging: return ([], [])
        case .verdict(let v, _, _):
            if v.isCorrect { return ([], []) }
            return ([arrow(replyUCI, .threat)].compactMap { $0 }, [])
        case .shown(let onAnswer):
            guard let q = step.quiz else { return (beatArrows, step.beat.circles) }
            if onAnswer { return ([arrow(q.best, .best), arrow(q.played, .threat)].compactMap { $0 }, []) }
            var out = beatArrows
            if let r = arrow(q.refutation.first, .threat), !out.contains(where: { $0.from == r.from && $0.to == r.to }) { out.insert(r, at: 0) }
            return (Array(out.prefix(3)), step.beat.circles)
        case .explained: return (beatArrows, step.beat.circles)
        }
    }

    /// The engine's answer to a wrong try (UCI), kept for its arrow.
    @ObservationIgnored private var replyUCI: String?

    // MARK: Labels

    /// "9\u{2026}Nbd7": the review's best move at the question.
    var bestLabel: String? { label(current.quiz?.best) }
    var playedLabel: String? { label(current.quiz?.played) }
    var refutationLabel: String? {
        guard let app, let q = current.quiz, let r = q.refutation.first, app.game.nodes.indices.contains(current.nodeID) else { return nil }
        return StoryBeats.moveLabel(r, from: app.game.nodes[current.nodeID].position)
    }

    private func label(_ uci: String?) -> String? {
        guard let app, let q = current.quiz, let uci, app.game.nodes.indices.contains(q.parentID) else { return nil }
        return StoryBeats.moveLabel(uci, from: app.game.nodes[q.parentID].position)
    }

    // MARK: Transport

    func start(at i: Int = 0) { show(i) }

    func next() { guard canGoForward else { return }; go(to: index + 1) }
    func previous() { guard canGoBack else { return }; go(to: index - 1) }

    func go(to i: Int) {
        guard steps.indices.contains(i) else { return }
        show(i)
        if isPlaying { playStep() }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    /// Narrated, auto-advancing: questions are answered on the spot, every beat is read out.
    func play() {
        guard !steps.isEmpty else { return }
        isPlaying = true
        playStep()
    }

    func pause() {
        isPlaying = false
        task?.cancel(); task = nil
        stopSpeaking()
    }

    /// Reads the current beat aloud, or stops reading.
    func toggleSpeech() {
        if isSpeaking { stopSpeaking(); return }
        let text = current.beat.narration
        isSpeaking = true
        speechTask = Task { [weak self] in
            await self?.narrator.speak(text)
            guard let self, !Task.isCancelled else { return }
            self.isSpeaking = false
        }
    }

    private func stopSpeaking() {
        speechTask?.cancel(); speechTask = nil
        narrator.stop()
        isSpeaking = false
    }

    func stop() {
        isPlaying = false
        task?.cancel(); task = nil
        judgeTask?.cancel(); judgeTask = nil
        travelTask?.cancel(); travelTask = nil
        stopSpeaking()
    }

    // MARK: Beats

    /// Puts beat `i` on the board: the question position for a quiz, else the beat's own position.
    func show(_ i: Int) {
        task?.cancel(); task = nil
        judgeTask?.cancel(); judgeTask = nil
        stopSpeaking()
        index = i
        replyUCI = nil
        epoch += 1
        let s = steps[i]
        phase = s.quiz == nil ? .explained : .asking
        travel(to: s.quiz?.parentID ?? s.nodeID)
        app?.refreshEngine()
    }

    /// "Try again": back to the question position.
    func clearAttempt() {
        guard current.quiz != nil else { return }
        if case .verdict(let v, _, _) = phase, !v.isCorrect { phase = .asking; replyUCI = nil }
    }

    /// "Show me": the best move on the question, then the game's move and what punished it.
    func reveal() {
        guard let q = current.quiz else { return }
        judgeTask?.cancel(); judgeTask = nil
        replyUCI = nil
        phase = .shown(onAnswer: true)
        epoch += 1
        travel(to: q.parentID)
        app?.refreshEngine()
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.answerHold))
            guard let self, !Task.isCancelled else { return }
            self.phase = .shown(onAnswer: false)
            self.epoch += 1
            self.travel(to: self.current.nodeID)
            self.task = nil
            if self.isPlaying { self.playStep() }
        }
    }

    /// Judges a try at the question (see `BetterMove`). The move is never added to the game.
    func submit(_ move: Move) {
        guard acceptsMove, let q = current.quiz, let app else { return }
        phase = .judging(move)
        replyUCI = nil
        let history = app.game.engineHistory(to: q.parentID)
        let before = app.game.nodes[q.parentID].position
        judgeTask?.cancel()
        judgeTask = Task { [weak self] in
            var eval: Eval?, reply: String?
            if move.uci != q.best && move.uci != q.played, let after = try? before.applying(move) {
                if after.legalMoves().isEmpty {
                    eval = after.isCheck ? .checkmate(winner: q.side) : .cp(0)
                } else if let line = try? await ToolEngine.shared.evaluate(rootFEN: history.rootFEN, moves: history.moves + [move.uci],
                                                                           whiteToMove: after.turn == .white) {
                    eval = line.eval; reply = line.pv.first
                }
            }
            guard let self, !Task.isCancelled, self.phase == .judging(move) else { return }
            if move.uci == q.played { reply = q.refutation.first }
            let replyText: String? = reply.flatMap { r in (try? before.applying(move)).flatMap { StoryBeats.moveLabel(r, from: $0) } }
            let v = BetterMove.judge(tried: move.uci, side: q.side, best: q.best, bestEval: q.bestEval, played: q.played,
                                     triedEval: eval, reply: replyText)
            self.replyUCI = v.isCorrect ? nil : reply
            self.phase = .verdict(v, tried: move, reply: replyText)
            self.epoch += 1
            self.judgeTask = nil
            self.app?.refreshEngine()
        }
    }

    /// Plays the current beat: answers its question, reads it out, then moves on.
    private func playStep() {
        task?.cancel(); task = nil
        if current.quiz != nil, !isRevealed || phase == .shown(onAnswer: true) {
            if phase != .shown(onAnswer: true) { reveal() }
            return                                   // `reveal` continues the play once the game move is on the board
        }
        let text = current.beat.narration
        task = Task { [weak self] in
            guard let self else { return }
            await self.travelTask?.value
            guard !Task.isCancelled else { return }
            self.isSpeaking = true
            let started = ContinuousClock.now
            await self.narrator.speak(text)
            self.isSpeaking = false
            // A voice that fails at once still leaves time to read the beat.
            let left = Duration.seconds(LessonPlayer.readingTime(text)) - (ContinuousClock.now - started)
            if left > .zero { try? await Task.sleep(for: left) }
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            self.task = nil
            if self.canGoForward { self.go(to: self.index + 1) } else { self.isPlaying = false }
        }
    }

    /// Goes to `target`, replaying the game moves in between so the pieces slide (see `PieceMotion.hops`).
    private func travel(to target: Int) {
        travelTask?.cancel(); travelTask = nil
        guard let app else { nodeID = target; return }
        let hops = PieceMotion.hops(from: app.currentID, to: target) { app.game.nodes[$0].parent }
        guard let first = hops.first else { nodeID = target; return }
        nodeID = first
        app.goto(first)
        guard hops.count > 1 else { return }
        let rest = Array(hops.dropFirst())
        travelTask = Task { [weak self] in
            for n in rest {
                try? await Task.sleep(for: .seconds(Self.secondsPerHop))
                guard !Task.isCancelled, let self, let app = self.app else { return }
                self.nodeID = n
                app.goto(n)
            }
            self?.travelTask = nil
        }
    }
}
