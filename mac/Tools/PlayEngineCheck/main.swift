// Headless check of UCIEngine the way PlaySession drives it. Not part of the app target.
// Run via mac/scripts/check-play-engine.sh, which compiles this with the real UCIEngine.swift and the
// ChessCore sources against mac/vendor/bin/stockfish. Nothing is opened on screen.
import Foundation
import ChessCore

func say(_ s: String) { print(s); fflush(stdout) }

let binary = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "mac/vendor/bin/stockfish")
let games = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 3 : 3
let thinkMillis = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 200 : 200
/// Other engines the app keeps running beside the play engine (live analysis, the AI tool), started and left idle.
let idleEngines = CommandLine.arguments.count > 4 ? Int(CommandLine.arguments[4]) ?? 2 : 2
var failures = 0

/// Progress stamp; a background thread fails the run when nothing moves for 20 s (a stuck read never returns).
nonisolated(unsafe) var lastProgress = Date()
func progress() { lastProgress = Date() }
Thread.detachNewThread {
    while true {
        Thread.sleep(forTimeInterval: 1)
        if Date().timeIntervalSince(lastProgress) > 20 { say("HANG: no engine progress for 20 s"); say("FAIL play engine check"); exit(1) }
    }
}

/// One engine move as PlaySession.think runs it: a fresh MainActor task iterating the search stream.
/// Returns the move, or nil when the stream ended without one. Flags a hang past `thinkMillis` + 3 s.
@MainActor
func engineMove(_ engine: UCIEngine, _ position: Position, label: String) async -> String? {
    let task = Task { @MainActor () -> String? in
        do {
            let stream = try await engine.search(fen: position.fen, limit: .moveTime(thinkMillis), multiPV: 1)
            var best: String?
            for await event in stream {
                if case .finished(let move, let completed) = event, completed { best = move }
            }
            return best
        } catch { say("FAIL \(label): \(error)"); return nil }
    }
    let watchdog = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(thinkMillis + 3000))
        if !Task.isCancelled { say("HANG \(label): no bestmove after \(thinkMillis + 3000) ms (fen \(position.fen))") }
    }
    let r = await task.value
    watchdog.cancel()
    progress()
    return r
}

/// A search that the session abandons after `after` ms (the user browsed away, took back, resigned...).
@MainActor
func abandonedSearch(_ engine: UCIEngine, _ position: Position, after: Int) async {
    let task = Task { @MainActor in
        guard let stream = try? await engine.search(fen: position.fen, limit: .moveTime(thinkMillis), multiPV: 1) else { return }
        for await _ in stream {}
    }
    if after > 0 { try? await Task.sleep(for: .milliseconds(after)) }
    task.cancel()
}

@MainActor
func run() async {
    var idle: [UCIEngine] = []
    for _ in 0..<idleEngines {
        let e = UCIEngine(executableURL: binary, threads: 1, hash: 16)
        try? await e.start()
        idle.append(e)
        progress()
    }
    say("\(idleEngines) idle engines started")
    // 1. Normal games at club strength: engine replies, "user" plays a random legal move.
    for g in 0..<games {
        let engine = UCIEngine(executableURL: binary, threads: 4, hash: 64)
        do { try await engine.start() } catch { say("FAIL start: \(error)"); failures += 1; return }
        await engine.setUCIOptions([("UCI_LimitStrength", "true"), ("UCI_Elo", "1800")])
        var pos = Position.start
        var plies = 0
        while pos.gameEnd == nil, plies < 80 {
            if plies % 2 == 0 {
                guard let uci = await engineMove(engine, pos, label: "game \(g) ply \(plies)"),
                      let m = pos.move(fromUCI: uci) else { say("FAIL game \(g) ply \(plies): no move"); failures += 1; break }
                pos = try! pos.applying(m)
            } else {
                // Sometimes the user browses away mid-think and comes back (cancel + new search).
                if Int.random(in: 0..<4) == 0 { await abandonedSearch(engine, pos, after: Int.random(in: 0...40)) }
                pos = try! pos.applying(pos.legalMoves().randomElement()!)
            }
            plies += 1
        }
        say("game \(g): \(plies) plies")
        await engine.stop(); await engine.shutdown()
    }

    // 2. Rapid cancel / search sequences on one engine, then a real search must still answer.
    let engine = UCIEngine(executableURL: binary, threads: 4, hash: 64)
    try? await engine.start()
    await engine.setUCIOptions([("UCI_LimitStrength", "true"), ("UCI_Elo", "1800")])
    var pos = Position.start
    for i in 0..<60 {
        for _ in 0..<Int.random(in: 1...3) { await abandonedSearch(engine, pos, after: Int.random(in: 0...15)) }
        if i % 10 == 0 { await engine.setUCIOptions([("UCI_Elo", String(Int.random(in: 1320...3190)))]) }
        guard let uci = await engineMove(engine, pos, label: "stress \(i)"), let m = pos.move(fromUCI: uci) else {
            say("FAIL stress \(i): no move"); failures += 1; continue
        }
        pos = try! pos.applying(m)
        if pos.gameEnd != nil { pos = .start }
    }
    // 3. The watchdog's recovery: restart mid-search ends the wait, and the next search runs on a fresh process.
    let waiting = Task { @MainActor () -> Bool in
        guard let stream = try? await engine.search(fen: pos.fen, limit: .moveTime(5000), multiPV: 1) else { return true }
        for await _ in stream {}
        return true
    }
    try? await Task.sleep(for: .milliseconds(100))
    await engine.restart()
    let ended = await waiting.value
    let after = await engineMove(engine, pos, label: "after restart")
    if ended, let after, pos.move(fromUCI: after) != nil { say("restart: search ended, fresh engine replied \(after)") }
    else { say("FAIL restart"); failures += 1 }
    await engine.stop(); await engine.shutdown()
    for e in idle { await e.shutdown() }
    say(failures == 0 ? "PASS play engine check" : "FAIL play engine check: \(failures) failures")
}

await run()
exit(failures == 0 ? 0 : 1)
