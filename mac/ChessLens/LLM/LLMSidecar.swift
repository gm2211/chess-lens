import Foundation
import os

let llmLog = Logger(subsystem: "app.chesslens.ChessLens", category: "llm")

struct LLMModel: Sendable, Equatable, Hashable, Identifiable {
    let id: String
    let name: String
}

/// One provider's status from the sidecar.
struct LLMStatus: Sendable, Equatable {
    /// Usable now: signed in, or a key is stored and the provider has not rejected it.
    var ready = false
    /// Account label (usually an email). Never a token or key.
    var account: String?
    var models: [LLMModel] = []
    /// Sidecar error code when the model list could not be fetched ("reconnect-required" means the credential was rejected).
    var error: String?
    /// A sign-in is waiting for a pasted `CODE#STATE` (Claude paste fallback).
    var awaitingCode = false
}

/// Static description of a sidecar provider, from the `providers` command.
struct LLMProviderInfo: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    /// "oauth", "apiKey" or "both".
    let authKind: String
    let setupText: String
    let setupURL: String
    /// "loopback", "loopback+paste", "device" or "" (key only).
    let flow: String
}

enum LLMError: Error, LocalizedError, Equatable {
    case executableMissing
    case launchFailed(String)
    case terminated
    case canceled
    /// An error reported by the sidecar. `code` is a sidecar error code
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
        case url(URL, userCode: String?)
        case delta(String)
        case done([String: Sendable])
        case failed(LLMError)
    }

    private let contents: URL?
    private var process: Process?
    private var input: FileHandle?
    private var readTask: Task<Void, Never>?
    private var output: FileHandle?
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

    /// Metadata for every provider the sidecar offers.
    func providers() async throws -> [LLMProviderInfo] {
        let r = try await request(["type": "providers"])
        return (r["providers"] as? [[String: String]] ?? []).compactMap { p in
            guard let id = p["id"], let name = p["name"] else { return nil }
            return LLMProviderInfo(id: id, name: name, authKind: p["authKind"] ?? "apiKey", setupText: p["setupText"] ?? "",
                                   setupURL: p["setupURL"] ?? "", flow: p["flow"] ?? "")
        }
    }

    func status(provider: String) async throws -> LLMStatus {
        Self.parseStatus(try await request(["type": "status", "provider": provider]))
    }

    /// OAuth providers: `onURL` receives the authorization URL (open it with NSWorkspace) and, for device-code
    /// flows, the code to enter; the call returns once the user finishes (up to ~5 minutes) or, for Claude, as soon as
    /// the paste fallback is waiting for a code (`awaitingCode`). Key providers: pass `apiKey`; the sidecar validates it
    /// against the provider and stores it in the Keychain. `paste` skips Claude's loopback and goes straight to the code flow.
    func signIn(provider: String, apiKey: String? = nil, paste: Bool = false,
                onURL: @escaping @Sendable (URL, String?) -> Void = { _, _ in }) async throws -> LLMStatus {
        let id = newID()
        var body: [String: Any] = ["type": "signIn", "provider": provider]
        if let apiKey { body["apiKey"] = apiKey }
        if paste { body["mode"] = "paste" }
        let events = try send(body, id: id)
        return try await withTaskCancellationHandler {
            for await e in events {
                switch e {
                case .url(let u, let code): onURL(u, code)
                case .done(let r): return Self.parseStatus(r)
                case .failed(let err): throw err
                case .delta: break
                }
            }
            throw Task.isCancelled ? LLMError.canceled : LLMError.terminated
        } onCancel: { Task { await self.cancel(id) } }
    }

    /// Finishes a paste-code sign-in (the `CODE#STATE` string the console page shows).
    func submitCode(provider: String, code: String) async throws -> LLMStatus {
        Self.parseStatus(try await request(["type": "submitCode", "provider": provider, "code": code]))
    }

    func signOut(provider: String) async throws {
        _ = try await request(["type": "signOut", "provider": provider])
    }

    /// Diagnostic: true when the sidecar can write, read and delete a throwaway Keychain item under the current sandbox.
    func keychainWorks() async throws -> Bool {
        try await request(["type": "probe"])["keychain"] as? Bool ?? false
    }

    /// Streams the model's answer as text chunks. Cancelling the consuming task (or breaking out of the loop)
    /// cancels the request. `model` nil uses the first model the provider offers.
    nonisolated func complete(provider: String, model: String? = nil, system: String, prompt: String, maxTokens: Int? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body: [String: Any] = ["type": "complete", "provider": provider, "system": system, "prompt": prompt]
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
        output = handle
        // readabilityHandler rather than `handle.bytes.lines`: the async byte sequence never delivered the sidecar's
        // replies inside the app (it did in a command-line harness), so every request hung.
        let lines = AsyncStream<String> { cont in
            let buffer = LineBuffer()
            handle.readabilityHandler = { h in
                let data = h.availableData
                if data.isEmpty { h.readabilityHandler = nil; cont.finish(); return }
                for line in buffer.append(data) { cont.yield(line) }
            }
        }
        readTask = Task { [weak self] in
            for await line in lines {
                await self?.handle(line: line, gen: gen)
            }
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
        output?.readabilityHandler = nil
        output = nil
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
            c.yield(.url(u, userCode: obj["userCode"] as? String))
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
        return LLMStatus(ready: r["ready"] as? Bool ?? false, account: r["account"] as? String, models: models,
                         error: r["error"] as? String, awaitingCode: r["awaitingCode"] as? Bool ?? false)
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
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}
