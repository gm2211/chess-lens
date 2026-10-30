import Foundation
import os

let llmLog = Logger(subsystem: "app.chesslens.ChessLens", category: "llm")

struct LLMModel: Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
}

struct LLMStatus: Sendable, Equatable {
    var signedIn = false
    /// Account label (usually an email). Never a token.
    var account: String?
    var models: [LLMModel] = []
    /// Set when signed in but the model list could not be fetched.
    var modelsError: String?
}

enum LLMError: Error, LocalizedError, Equatable {
    case executableMissing
    case launchFailed(String)
    case terminated
    case canceled
    /// An error reported by the sidecar. `code` is one of the @byos/chatgpt-local codes
    /// (e.g. "reconnect-required", "consent-required", "busy", "storage-unavailable", "unavailable").
    case server(code: String, message: String)

    var errorDescription: String? {
        switch self {
        case .executableMissing: "The AI helper is missing from this build."
        case .launchFailed(let s): "The AI helper could not be started (\(s))."
        case .terminated: "The AI helper stopped unexpectedly."
        case .canceled: "Canceled."
        case .server(_, let m): m
        }
    }

    var needsSignIn: Bool {
        if case .server(let c, _) = self { return c == "reconnect-required" || c == "consent-required" }
        return false
    }
}

/// Wraps the Node sidecar (Contents/Helpers/sidecar-node running Resources/sidecar.mjs) speaking newline-delimited JSON on stdio.
/// Tokens stay in the sidecar; this side only sees account labels, model ids and text.
/// The process starts on first use and is restarted on the next call after it dies.
actor LLMSidecar {
    static let shared = LLMSidecar()

    private enum Event: Sendable {
        case url(URL)
        case delta(String)
        case done([String: Sendable])
        case failed(LLMError)
    }

    private let contents: URL?
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var generation = 0
    private var nextID = 0
    private var pending: [String: AsyncStream<Event>.Continuation] = [:]

    /// `contents` is the app's Contents folder (Helpers/sidecar-node, Helpers/sidecar-keyring.node, Resources/sidecar.mjs).
    init(contents: URL? = LLMSidecar.defaultContents) {
        self.contents = contents
    }

    static var defaultContents: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents")
        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Helpers/sidecar-node").path) ? url : nil
    }

    // MARK: API

    func status() async throws -> LLMStatus {
        let r = try await request(["type": "status"])
        return Self.parseStatus(r)
    }

    /// Starts the official Sign in with ChatGPT flow. `openURL` receives the loopback authorization URL as soon
    /// as it exists (open it with NSWorkspace); the call returns once the user finishes (up to ~5 minutes).
    func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws -> LLMStatus {
        let id = newID()
        let events = try send(["type": "signIn"], id: id)
        return try await withTaskCancellationHandler {
            for await e in events {
                switch e {
                case .url(let u): openURL(u)
                case .done(let r): return Self.parseStatus(r)
                case .failed(let err): throw err
                case .delta: break
                }
            }
            throw Task.isCancelled ? LLMError.canceled : LLMError.terminated
        } onCancel: { Task { await self.cancel(id) } }
    }

    func signOut() async throws {
        _ = try await request(["type": "signOut"])
    }

    /// Diagnostic: true when the sidecar can write, read and delete a throwaway Keychain item under the current sandbox.
    func keychainWorks() async throws -> Bool {
        try await request(["type": "probe"])["keychain"] as? Bool ?? false
    }

    /// Streams the model's answer as text chunks. Cancelling the consuming task (or breaking out of the loop)
    /// cancels the request. `model` nil uses the first model the account offers.
    nonisolated func complete(model: String? = nil, system: String, prompt: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = ["type": "complete", "system": system, "prompt": prompt]
                    if let model { body["model"] = model }
                    if let maxTokens { body["maxTokens"] = maxTokens }
                    try await self.stream(body, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stops the sidecar. It restarts on the next call.
    func shutdown() {
        let p = process
        tearDown()
        p?.terminate()
    }

    // MARK: Requests

    private func stream(_ body: [String: Any], into out: AsyncThrowingStream<String, Error>.Continuation) async throws {
        let id = newID()
        let events = try send(body, id: id)
        try await withTaskCancellationHandler {
            for await e in events {
                switch e {
                case .delta(let s): out.yield(s)
                case .done: return
                case .failed(let err): throw err
                case .url: break
                }
            }
            throw Task.isCancelled ? LLMError.canceled : LLMError.terminated
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func request(_ body: [String: Any]) async throws -> [String: Sendable] {
        let id = newID()
        let events = try send(body, id: id)
        return try await withTaskCancellationHandler {
            for await e in events {
                switch e {
                case .done(let r): return r
                case .failed(let err): throw err
                default: break
                }
            }
            throw Task.isCancelled ? LLMError.canceled : LLMError.terminated
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func newID() -> String {
        nextID += 1
        return String(nextID)
    }

    private func send(_ body: [String: Any], id: String) throws -> AsyncStream<Event> {
        try startIfNeeded()
        var msg = body
        msg["id"] = id
        guard let input, let data = try? JSONSerialization.data(withJSONObject: msg) else { throw LLMError.terminated }
        let (stream, cont) = AsyncStream<Event>.makeStream()
        pending[id] = cont
        do {
            try input.write(contentsOf: data + [0x0A])
        } catch {
            pending[id] = nil
            cont.finish()
            tearDown()
            throw LLMError.terminated
        }
        return stream
    }

    private func cancel(_ id: String) {
        guard let input, pending[id] != nil else { return }
        let msg: [String: Any] = ["id": "c" + id, "type": "cancel", "target": id]
        if let data = try? JSONSerialization.data(withJSONObject: msg) { try? input.write(contentsOf: data + [0x0A]) }
    }

    // MARK: Process

    private func startIfNeeded() throws {
        if let p = process, p.isRunning { return }
        tearDown()
        guard let contents else { throw LLMError.executableMissing }
        let p = Process()
        p.executableURL = contents.appendingPathComponent("Helpers/sidecar-node")
        p.arguments = [contents.appendingPathComponent("Resources/sidecar.mjs").path]
        p.currentDirectoryURL = FileManager.default.temporaryDirectory
        // Minimal environment: no inherited secrets.
        p.environment = ["HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory(), "NODE_ENV": "production",
                         "CHESSLENS_KEYRING_ADDON": contents.appendingPathComponent("Helpers/sidecar-keyring.node").path]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        generation += 1
        let gen = generation
        p.terminationHandler = { _ in Task { await self.exited(gen) } }
        do { try p.run() } catch { throw LLMError.launchFailed(error.localizedDescription) }
        process = p
        input = stdin.fileHandleForWriting
        let handle = stdout.fileHandleForReading
        readTask = Task { [weak self] in
            do {
                for try await line in handle.bytes.lines {
                    await self?.handle(line: line, gen: gen)
                }
            } catch {}
        }
    }

    private func exited(_ gen: Int) {
        guard gen == generation else { return }
        llmLog.error("sidecar exited")
        tearDown()
    }

    /// Fails every in-flight request and forgets the process so the next call starts a fresh one.
    private func tearDown() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        process = nil
        try? input?.close()
        input = nil
        let waiting = pending
        pending = [:]
        for (_, c) in waiting {
            c.yield(.failed(.terminated))
            c.finish()
        }
    }

    private func handle(line: String, gen: Int) {
        guard gen == generation,
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = obj["id"] as? String ?? (obj["id"] as? Int).map(String.init),
              let c = pending[id] else { return }
        if let url = obj["url"] as? String, let u = URL(string: url) {
            c.yield(.url(u))
        } else if let d = obj["delta"] as? String {
            c.yield(.delta(d))
        } else if let e = obj["error"] as? [String: Any] {
            let code = e["code"] as? String ?? "unavailable"
            let err: LLMError = code == "canceled" ? .canceled : .server(code: code, message: e["message"] as? String ?? "The operation could not be completed.")
            c.yield(.failed(err))
            c.finish()
            pending[id] = nil
        } else if obj["done"] as? Bool == true {
            c.yield(.done(Self.sendable(obj)))
            c.finish()
            pending[id] = nil
        }
        // progress events are ignored
    }

    private static func sendable(_ obj: [String: Any]) -> [String: Sendable] {
        var out: [String: Sendable] = [:]
        for (k, v) in obj {
            if let s = v as? String { out[k] = s }
            else if let b = v as? Bool { out[k] = b }
            else if let a = v as? [[String: String]] { out[k] = a }
        }
        return out
    }

    private static func parseStatus(_ r: [String: Sendable]) -> LLMStatus {
        let models = (r["models"] as? [[String: String]] ?? []).compactMap { m in
            m["id"].map { LLMModel(id: $0, name: m["name"] ?? $0) }
        }
        return LLMStatus(signedIn: r["signedIn"] as? Bool ?? false, account: r["account"] as? String,
                         models: models, modelsError: r["modelsError"] as? String)
    }
}
