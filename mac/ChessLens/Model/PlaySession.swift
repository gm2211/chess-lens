import Foundation
import Observation
import ChessCore

/// What the player picked in the setup sheet. Strength, think time and the hide-evaluation switch are remembered.
struct PlaySetup: Equatable {
    var userSide: Side
    var strength: PlayStrength = .club
    var thinkMillis = 1000
    var hideEvaluation = true

    static let thinkChoices = [500, 1000, 3000]

    private enum Key {
        static let strength = "play.strength", think = "play.thinkMillis", hide = "play.hideEvaluation"
    }

    static func saved(side: Side) -> PlaySetup {
        let d = UserDefaults.standard
        var s = PlaySetup(userSide: side)
        if let raw = d.string(forKey: Key.strength), let v = PlayStrength(rawValue: raw) { s.strength = v }
        let ms = d.integer(forKey: Key.think)
        if thinkChoices.contains(ms) { s.thinkMillis = ms }
        if let h = d.object(forKey: Key.hide) as? Bool { s.hideEvaluation = h }
        return s
    }

    func save() {
        let d = UserDefaults.standard
        d.set(strength.rawValue, forKey: Key.strength)
        d.set(thinkMillis, forKey: Key.think)
        d.set(hideEvaluation, forKey: Key.hide)
    }
}

/// One game against Stockfish, played into the app's game tree. It runs its own engine process so the
/// strength limits never touch the analysis engine. The session follows `tip`, the last node it played to;
/// browsing away from `tip` pauses it, and resuming continues from wherever the board is.
@Observable @MainActor
final class PlaySession {
    enum Ending: Equatable {
        case game(GameEnd)
        case resigned
    }

    let setup: PlaySetup
    private(set) var tip: Int
    /// Take back never goes before this node (where the session started or was last resumed).
    private(set) var anchor: Int
    private(set) var ending: Ending?
    private(set) var failure: String?
    private(set) var thinking = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let engine: UCIEngine
    @ObservationIgnored private var thinkTask: Task<Void, Never>?
    @ObservationIgnored private var prepared = false
    @ObservationIgnored private var enginePlaying = false

    init(app: AppModel, setup: PlaySetup, start: Int) {
        self.app = app
        self.setup = setup
        tip = start
        anchor = start
        engine = UCIEngine(executableURL: UCIEngine.defaultExecutableURL,
                           threads: min(4, UCIEngine.performanceCoreCount), hash: 64)
    }

    // MARK: State

    var userSide: Side { setup.userSide }
    var isActive: Bool { ending == nil && failure == nil }
    var isPaused: Bool { isActive && app?.currentID != tip }
    private var tipTurn: Side? { app?.game.nodes[tip].position.turn }
    var isUserTurn: Bool { isActive && !isPaused && tipTurn == userSide }
    /// The board takes input only on the user's turn (the engine's own move passes through too).
    var acceptsInput: Bool { isUserTurn || enginePlaying }
    /// Eval bar, engine lines and arrows stay hidden until the game ends.
    var hidesEvaluation: Bool { setup.hideEvaluation && isActive }
    var canTakeBack: Bool {
        guard let app else { return false }
        return app.game.takeBackTarget(from: tip, userSide: userSide, anchor: anchor) != nil
    }

    var headline: String {
        "Playing Stockfish \u{00B7} \(setup.strength.detail) \u{00B7} You\u{2019}re \(userSide == .white ? "White" : "Black")"
    }

    var resultText: String? {
        switch ending {
        case .resigned: return "You resigned \u{2014} Stockfish wins"
        case .game(let end):
            if let w = end.winner { return "Checkmate \u{2014} \(w == userSide ? "you win" : "Stockfish wins")" }
            return end.title
        case nil: return nil
        }
    }

    // MARK: Flow

    func begin() { drive() }

    /// Called by the app after every navigation or move.
    func positionChanged() {
        guard isActive else { return }
        if app?.currentID == tip { drive() } else { cancelThinking() }
    }

    /// The app calls this when a move was accepted from the live tip.
    func noteMove(to id: Int) {
        tip = id
        if let end = app?.game.gameEnd(at: id) { finish(.game(end)) }
    }

    func resume() {
        guard let app, isActive else { return }
        tip = app.currentID
        anchor = tip
        if let end = app.game.gameEnd(at: tip) { finish(.game(end)); return }
        drive()
    }

    func takeBack() {
        guard let app, let target = app.game.takeBackTarget(from: tip, userSide: userSide, anchor: anchor) else { return }
        cancelThinking()
        let wasOver = !isActive
        ending = nil; failure = nil
        tip = target
        app.goto(target)
        if wasOver { app.refreshEngine() }
        drive()
    }

    func resign() {
        guard isActive else { return }
        finish(.resigned)
    }

    func end() {
        cancelThinking()
        let engine = engine
        Task { await engine.stop(); await engine.shutdown() }
    }

    // MARK: Engine

    private func drive() {
        cancelThinking()
        guard isActive, let app, app.currentID == tip else { return }
        if let end = app.game.gameEnd(at: tip) { finish(.game(end)); return }
        guard app.game.nodes[tip].position.turn != userSide else { return }
        thinking = true
        thinkTask = Task { await think() }
    }

    /// Cancelling the task ends its stream, which stops the search; no explicit stop (it could race a newer search).
    private func cancelThinking() {
        thinkTask?.cancel()
        thinkTask = nil
        thinking = false
    }

    private func think() async {
        guard let app else { return }
        let from = tip
        let position = app.game.nodes[from].position
        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await engine.start()
            if !prepared {
                await engine.setUCIOptions(setup.strength.uciOptions)
                prepared = true
            }
            let stream = try await engine.search(fen: position.fen, limit: .moveTime(setup.thinkMillis), multiPV: 1)
            var best: String?
            for await event in stream {
                if case .finished(let move, let completed) = event, completed { best = move }
            }
            if Task.isCancelled { return }
            guard let best, let move = position.move(fromUCI: best) else {
                fail("The engine did not return a move.")
                return
            }
            // Fast replies at low think times feel abrupt.
            let minimum = Duration.milliseconds(300)
            let elapsed = started.duration(to: clock.now)
            if elapsed < minimum { try? await Task.sleep(for: minimum - elapsed) }
            guard !Task.isCancelled, isActive, tip == from, app.currentID == from else { return }
            thinking = false
            enginePlaying = true
            app.play(move)
            enginePlaying = false
        } catch {
            if !Task.isCancelled { fail(error.localizedDescription) }
        }
    }

    private func fail(_ message: String) {
        cancelThinking()
        failure = message
        app?.refreshEngine()
    }

    private func finish(_ ending: Ending) {
        cancelThinking()
        self.ending = ending
        app?.refreshEngine()           // analysis comes back once the evaluation is no longer hidden
    }
}
