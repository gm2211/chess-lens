import Foundation
import ChessCore
import os

let engineLog = Logger(subsystem: "app.chesslens.ChessLens", category: "engine")

enum SearchLimit: Sendable, Equatable {
    /// `go infinite`, stopped by us once the depth passes `depthCap`.
    case infinite(depthCap: Int)
    /// `go depth N`.
    case depth(Int)
    /// `go depth N movetime T`: whichever comes first (the AI's engine tool).
    case depthTime(depth: Int, ms: Int)
    /// `go movetime N` (milliseconds): used when playing against the engine.
    case moveTime(Int)
}

enum EngineEvent: Sendable {
    case info(UCIInfo)
    /// The search ended. `completed` is false when it was stopped early.
    case finished(bestMove: String?, completed: Bool)
}

enum EngineError: Error, LocalizedError {
    case executableMissing
    case launchFailed(String)
    case handshakeFailed
    case terminated

    var errorDescription: String? {
        switch self {
        case .executableMissing: "The Stockfish engine is missing from this build."
        case .launchFailed(let s): "The engine could not be started (\(s))."
        case .handshakeFailed: "The engine did not respond."
        case .terminated: "The engine stopped unexpectedly."
        }
    }
}

/// Wraps a Stockfish child process speaking UCI. One search runs at a time; asking for a new one
/// stops the old one and waits for its `bestmove` first, so stale `info` lines never leak through.
actor UCIEngine {
    private struct Active {
        let id: Int
        let continuation: AsyncStream<EngineEvent>.Continuation
        let limit: SearchLimit
        var stopping = false
    }

    private let executableURL: URL?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readTask: Task<Void, Never>?
    private var startTask: Task<Void, Error>?
    private var started = false
    private var dead = false
    /// Bumped per launch so a killed process's late termination never marks its replacement dead.
    private var launches = 0

    private var active: Active?
    private var nextSearchID = 0
    private var ticket = 0
    private var currentMultiPV = 1
    private var threads: Int
    private var hash: Int
    private var appliedThreads = 0
    private var appliedHash = 0
    private var pendingOptions: [(name: String, value: String)] = []
    /// Every UCI option sent so far, replayed when a fresh process is launched after `restart()` or a crash.
    private var sentOptions: [(name: String, value: String)] = []
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var tokenWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    init(executableURL: URL?, threads: Int = UCIEngine.performanceCoreCount, hash: Int = 256) {
        self.executableURL = executableURL
        self.threads = threads
        self.hash = hash
    }

    /// Stored now, sent before the next search (never while one is running).
    func setOptions(threads: Int, hash: Int) {
        self.threads = threads
        self.hash = hash
    }

    /// Arbitrary UCI options (e.g. `UCI_Elo`), stored now and sent before the next search.
    func setUCIOptions(_ options: [(name: String, value: String)]) {
        pendingOptions.append(contentsOf: options)
    }

    static var defaultExecutableURL: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/stockfish")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Number of performance cores (falls back to half of the active cores).
    static var performanceCoreCount: Int {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &n, &size, nil, 0) == 0, n > 0 { return Int(n) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    // MARK: Lifecycle

    func start() async throws {
        if started { return }
        if let t = startTask { return try await t.value }
        let t = Task { try await self.launchAndHandshake() }
        startTask = t
        do { try await t.value } catch { startTask = nil; throw error }
    }

    private func launchAndHandshake() async throws {
        guard let url = executableURL else { throw EngineError.executableMissing }
        appliedThreads = 0; appliedHash = 0; currentMultiPV = 1
        launches += 1
        let generation = launches
        dead = false
        pendingOptions = sentOptions + pendingOptions
        sentOptions = []
        let p = Process()
        p.executableURL = url
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        let errPipe = Pipe()
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { engineLog.error("stderr: \(String(decoding: d, as: UTF8.self), privacy: .public)") }
        }
        p.terminationHandler = { [weak self] proc in
            engineLog.info("stockfish exited status=\(proc.terminationStatus)")
            Task { await self?.processDied(generation) }
        }
        do { try p.run() } catch {
            engineLog.error("launch failed: \(error.localizedDescription, privacy: .public)")
            throw EngineError.launchFailed(error.localizedDescription)
        }
        process = p
        input = inPipe.fileHandleForWriting
        let reader = outPipe.fileHandleForReading
        output = reader
        _ = errPipe
        // readabilityHandler rather than `reader.bytes.lines`: Foundation runs every FileHandle.AsyncBytes read on one
        // serial queue (AsyncBytesIOActorQueue) with a blocking read(2), so an idle engine (live analysis stopped while
        // playing) parks that queue and the play engine's `bestmove` is never read: "Stockfish is thinking..." forever.
        let lines = AsyncStream<String> { cont in
            let buffer = LineBuffer()
            reader.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; cont.finish(); return }
                for line in buffer.append(data) { cont.yield(line) }
            }
        }
        readTask = Task { [weak self] in
            for await line in lines {
                await self?.handle(line: line)
            }
        }
        send("uci")
        await waitFor("uciok")
        if dead { throw EngineError.handshakeFailed }
        // The nets ship as files in Resources/Networks (the bigger one is the default "EvalFile").
        if let dir = Bundle.main.resourceURL?.appendingPathComponent("Networks"),
           let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            let nets = files.filter { $0.pathExtension == "nnue" }
                .sorted { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            if let big = nets.first { send("setoption name EvalFile value \(big.path)") }
            if nets.count > 1, let small = nets.last { send("setoption name EvalFileSmall value \(small.path)") }
        }
        sendPendingOptions()
        send("setoption name MultiPV value 1")
        send("isready")
        await waitFor("readyok")
        if dead { throw EngineError.handshakeFailed }
        started = true
    }

    func shutdown() {
        guard let p = process, p.isRunning else { return }
        send("quit")
        // Give it a moment, then make sure.
        Task { [p] in
            try? await Task.sleep(for: .milliseconds(300))
            if p.isRunning { p.terminate() }
        }
        readTask?.cancel()
        output?.readabilityHandler = nil
    }

    /// Kills a process that stopped answering. Waiting searches end without a move (or throw `terminated`);
    /// the next `start()` or `search` launches a fresh process with the same options.
    func restart() {
        engineLog.error("restarting an unresponsive engine")
        let p = process
        readTask?.cancel()
        output?.readabilityHandler = nil
        processDied(launches)
        launches += 1                      // the old process's termination handler is now ignored
        process = nil; input = nil; output = nil
        if let p, p.isRunning { p.terminate() }
    }

    private func processDied(_ generation: Int) {
        guard generation == launches else { return }
        dead = true
        startTask = nil                    // so `start()` launches again instead of returning the old result
        started = false
        if let a = active { a.continuation.finish() }
        active = nil
        for w in stopWaiters { w.resume() }
        stopWaiters = []
        for (_, ws) in tokenWaiters { for w in ws { w.resume() } }
        tokenWaiters = [:]
    }

    // MARK: IO

    private func send(_ command: String) {
        guard let input, !dead else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }

    private func waitFor(_ token: String) async {
        if dead { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            tokenWaiters[token, default: []].append(c)
        }
    }

    private func handle(line: String) {
        if let ws = tokenWaiters.removeValue(forKey: line) {
            for w in ws { w.resume() }
            return
        }
        if line.hasPrefix("info ") {
            guard var a = active, !a.stopping, let info = UCI.parseInfo(line) else { return }
            if case .infinite(let cap) = a.limit, info.depth > cap {
                a.stopping = true
                active = a
                send("stop")
                return
            }
            a.continuation.yield(.info(info))
        } else if line.hasPrefix("bestmove") {
            let parsed = UCI.parseBestMove(line)
            if let a = active {
                let completed: Bool
                if case .infinite = a.limit { completed = false } else { completed = !a.stopping }
                a.continuation.yield(.finished(bestMove: parsed?.best, completed: completed))
                a.continuation.finish()
            }
            active = nil
            let ws = stopWaiters
            stopWaiters = []
            for w in ws { w.resume() }
        }
    }

    private func sendPendingOptions() {
        if threads != appliedThreads { send("setoption name Threads value \(threads)"); appliedThreads = threads }
        if hash != appliedHash { send("setoption name Hash value \(hash)"); appliedHash = hash }
        for o in pendingOptions { send("setoption name \(o.name) value \(o.value)") }
        sentOptions.append(contentsOf: pendingOptions)
        pendingOptions = []
    }

    // MARK: Search

    private func stopActive() async {
        guard var a = active else { return }
        if !a.stopping {
            a.stopping = true
            active = a
            send("stop")
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if active == nil { c.resume() } else { stopWaiters.append(c) }
        }
    }

    private func cancelIfActive(_ id: Int) {
        guard var a = active, a.id == id, !a.stopping else { return }
        a.stopping = true
        active = a
        send("stop")
    }

    /// Starts a search, first stopping (and draining) any previous one.
    func search(fen: String, limit: SearchLimit, multiPV: Int) async throws -> AsyncStream<EngineEvent> {
        try await start()
        if dead { throw EngineError.terminated }
        ticket += 1
        let mine = ticket
        await stopActive()
        guard mine == ticket else { return AsyncStream { $0.finish() } }   // superseded while waiting
        if dead { throw EngineError.terminated }
        if threads != appliedThreads || hash != appliedHash || !pendingOptions.isEmpty {
            sendPendingOptions()
            send("isready")
            await waitFor("readyok")
            guard mine == ticket else { return AsyncStream { $0.finish() } }
            if dead { throw EngineError.terminated }
        }
        if multiPV != currentMultiPV {
            send("setoption name MultiPV value \(multiPV)")
            currentMultiPV = multiPV
        }
        nextSearchID += 1
        let id = nextSearchID
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self, bufferingPolicy: .bufferingNewest(256))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancelIfActive(id) }
        }
        active = Active(id: id, continuation: continuation, limit: limit)
        send("position fen \(fen)")
        switch limit {
        case .infinite: send("go infinite")
        case .depth(let d): send("go depth \(d)")
        case .depthTime(let d, let ms): send("go depth \(d) movetime \(ms)")
        case .moveTime(let ms): send("go movetime \(ms)")
        }
        return stream
    }

    /// Stops whatever is running.
    func stop() async {
        ticket += 1
        await stopActive()
    }

    func newGame() async {
        await stop()
        send("ucinewgame")
        send("isready")
        await waitFor("readyok")
    }
}

/// Splits stdout chunks into newline-terminated lines. Only touched from the pipe's readability handler, which
/// FileHandle calls serially.
private final class LineBuffer: @unchecked Sendable {
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            var line = pending[pending.startIndex..<nl]
            if line.last == 0x0D { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}
