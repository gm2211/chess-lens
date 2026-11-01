import SwiftUI
import AppKit
import Observation
import os
import ChessCore

private let aiLog = Logger(subsystem: "app.chesslens", category: "ai")

enum AIAuthKind: Equatable { case oauth, apiKey, both, onDevice }

enum AIProviderID: String, CaseIterable, Codable, Identifiable {
    case chatgpt, claude, claudeAPI, openrouter, grok, groq, huggingface, apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatgpt: "ChatGPT"
        case .claude: "Claude"
        case .claudeAPI: "Claude API"
        case .openrouter: "OpenRouter"
        case .grok: "Grok"
        case .groq: "Groq"
        case .huggingface: "Hugging Face"
        case .apple: "Apple Intelligence"
        }
    }

    var systemImage: String {
        switch self {
        case .chatgpt: "bubble.left.and.text.bubble.right"
        case .claude: "sparkle"
        case .claudeAPI: "key"
        case .openrouter: "arrow.triangle.branch"
        case .grok: "bolt"
        case .groq: "speedometer"
        case .huggingface: "face.smiling"
        case .apple: "apple.logo"
        }
    }

    var authKind: AIAuthKind {
        switch self {
        case .chatgpt, .claude: .oauth
        case .grok: .both
        case .claudeAPI, .openrouter, .groq, .huggingface: .apiKey
        case .apple: .onDevice
        }
    }

    /// One line shown under the sign-in controls.
    var setupHint: String {
        switch self {
        case .chatgpt: "Uses your ChatGPT plan. Sign-in tokens stay in your Keychain."
        case .claude: "Uses your Claude Pro or Max plan. Sign-in tokens stay in your Keychain."
        case .claudeAPI: "Create a key in Claude Console. Max and Team plans include monthly API credits."
        case .openrouter: "Create a key at openrouter.ai. One key reaches many models."
        case .grok: "Sign in with SuperGrok, or paste an xAI API key."
        case .groq: "Create a key at console.groq.com."
        case .huggingface: "Create an access token with Inference Providers permission."
        case .apple: "Runs on this Mac. Nothing is sent anywhere."
        }
    }

    /// Where to get a key, for providers that take one.
    var setupURL: URL? {
        switch self {
        case .claudeAPI: URL(string: "https://platform.claude.com/settings/keys")
        case .openrouter: URL(string: "https://openrouter.ai/settings/keys")
        case .grok: URL(string: "https://console.x.ai")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .huggingface: URL(string: "https://huggingface.co/settings/tokens")
        case .chatgpt, .claude, .apple: nil
        }
    }

    var usesSidecar: Bool { self != .apple }
}

struct AIProviderState: Equatable {
    var ready = false
    /// Account label (email, "API key", "On-device"). Never a key or token.
    var account: String?
    var models: [LLMModel] = []
    /// Why it can't be used right now, in words for the user.
    var problem: String?
}

/// The selected AI provider and every provider's status. Keys and tokens live in the Keychain, behind the sidecar;
/// this type only ever sees account labels, model ids and text.
@MainActor @Observable
final class AIHub {
    static let shared = AIHub()

    private static let selectedKey = "ai.provider"
    private static func modelKey(_ id: AIProviderID) -> String { "ai.model.\(id.rawValue)" }

    private var _selected: AIProviderID
    private var chosen: [AIProviderID: String]

    /// The provider commentary uses. Persisted.
    var selected: AIProviderID {
        get { _selected }
        set {
            guard newValue != _selected else { return }
            _selected = newValue
            defaults.set(newValue.rawValue, forKey: Self.selectedKey)
            onSelectionChange?()
        }
    }

    /// Model for `selected` (nil = the provider's first). Persisted per provider.
    var model: String? {
        get { chosen[_selected] }
        set {
            chosen[_selected] = newValue
            defaults.set(newValue, forKey: Self.modelKey(_selected))
            onSelectionChange?()
        }
    }

    private(set) var states: [AIProviderID: AIProviderState] = [:]
    /// Providers with a sign-in in progress (browser open, or waiting for a device code).
    private(set) var signingIn: Set<AIProviderID> = []
    /// Providers waiting for a pasted `CODE#STATE` (Claude fallback).
    private(set) var awaitingCode: Set<AIProviderID> = []
    /// Code to enter on the provider's page during a device-code sign-in (Grok).
    private(set) var deviceCode: [AIProviderID: String] = [:]
    /// The page the current sign-in opened, shown as a link in case the browser didn't come up.
    private(set) var signInURL: [AIProviderID: URL] = [:]

    var current: AIProviderState { states[selected] ?? AIProviderState() }
    var isReady: Bool { current.ready }

    /// Called after the user picks another provider or model, so AI work that is hung or failed can start over with it.
    @ObservationIgnored var onSelectionChange: (@MainActor () -> Void)?
    @ObservationIgnored private let sidecar: LLMSidecar
    @ObservationIgnored private let defaults: UserDefaults

    init(sidecar: LLMSidecar = .shared, defaults: UserDefaults = .standard) {
        self.sidecar = sidecar
        self.defaults = defaults
        _selected = defaults.string(forKey: Self.selectedKey).flatMap(AIProviderID.init(rawValue:)) ?? .chatgpt
        var chosen: [AIProviderID: String] = [:]
        for id in AIProviderID.allCases { if let m = defaults.string(forKey: Self.modelKey(id)), !m.isEmpty { chosen[id] = m } }
        // Before providers existed the only choice was a ChatGPT model, stored under "ai.model".
        if chosen[.chatgpt] == nil, let old = defaults.string(forKey: "ai.model"), !old.isEmpty { chosen[.chatgpt] = old }
        self.chosen = chosen
    }

    // MARK: Status

    /// Re-reads one provider's status (nil = all of them). Never signs in.
    func refresh(_ id: AIProviderID? = nil) async {
        let ids = id.map { [$0] } ?? AIProviderID.allCases
        await withTaskGroup(of: Void.self) { group in
            for p in ids { group.addTask { await self.load(p) } }
        }
    }

    private func load(_ id: AIProviderID) async {
        if id == .apple {
            let a = AppleIntelligence.availability()
            states[id] = AIProviderState(ready: a.ready, account: a.ready ? "On-device" : nil, models: [], problem: a.reason)
            return
        }
        do {
            let sidecar = self.sidecar
            apply(try await withTimeout(.seconds(20)) { try await sidecar.status(provider: id.rawValue) }, to: id)
        } catch is AITimedOut {
            states[id] = AIProviderState(problem: AIFailureText.timedOut(.inactive, provider: id.displayName))
        } catch {
            states[id] = AIProviderState(problem: error.localizedDescription)
        }
    }

    private func apply(_ s: LLMStatus, to id: AIProviderID) {
        states[id] = AIProviderState(ready: s.ready, account: s.account, models: s.models, problem: s.error.flatMap(Self.describe))
        if s.awaitingCode { awaitingCode.insert(id) } else { awaitingCode.remove(id) }
        if s.ready { deviceCode[id] = nil; signInURL[id] = nil }
        if let m = chosen[id], s.ready, !s.models.isEmpty, !s.models.contains(where: { $0.id == m }) {
            chosen[id] = nil; defaults.removeObject(forKey: Self.modelKey(id))
        }
    }

    private static func describe(_ code: String) -> String {
        switch code {
        case "reconnect-required", "consent-required": "Sign in again; the saved credential was rejected."
        case "quota": "Usage limit reached."
        default: "Couldn't load models."
        }
    }

    // MARK: Sign-in

    /// OAuth providers open the authorization URL in the browser and return when the user finishes (or, for Claude's
    /// paste fallback, when a code is awaited: see `awaitingCode`). Key providers pass `apiKey`; the sidecar validates it
    /// and stores it in the Keychain. `paste` skips Claude's loopback sign-in and goes straight to the code flow.
    func signIn(_ id: AIProviderID, apiKey: String? = nil, paste: Bool = false) async throws {
        guard id.usesSidecar else { throw LLMError.server(code: "unsupported", message: "Apple Intelligence needs no sign-in.") }
        signingIn.insert(id)
        signInURL[id] = nil
        defer { signingIn.remove(id); deviceCode[id] = nil }
        let status = try await sidecar.signIn(provider: id.rawValue, apiKey: apiKey, paste: paste) { [weak self] url, code in
            Task { @MainActor in
                if let code { self?.setDeviceCode(code, for: id) }
                self?.signInURL[id] = url
                Self.openInBrowser(url)
            }
        }
        if !status.awaitingCode { signInURL[id] = nil }
        apply(status, to: id)
    }

    static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { aiLog.error("Couldn't open \(url.host() ?? "", privacy: .public) in the browser: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func setDeviceCode(_ code: String, for id: AIProviderID) {
        if signingIn.contains(id) { deviceCode[id] = code }
    }

    /// Paste-code fallback: the `CODE#STATE` string the Claude console page shows.
    func submitCode(_ id: AIProviderID, code: String) async throws {
        apply(try await sidecar.submitCode(provider: id.rawValue, code: code), to: id)
    }

    func signOut(_ id: AIProviderID) async {
        if id.usesSidecar { try? await sidecar.signOut(provider: id.rawValue) }
        awaitingCode.remove(id)
        signInURL[id] = nil
        await load(id)
    }

    // MARK: Completion

    /// Streams the selected provider's answer as text chunks. Cancelling the consumer cancels the request. Fails with
    /// `AITimedOut` (and cancels the request) when nothing arrives for `inactivity`, or after `overall`.
    func complete(system: String, prompt: String, maxTokens: Int?,
                  inactivity: Duration = AITimeout.note.inactivity, overall: Duration? = nil) -> AsyncThrowingStream<String, Error> {
        let raw = selected == .apple
            ? AppleIntelligence.stream(system: system, prompt: prompt, maxTokens: maxTokens)
            : sidecar.complete(provider: selected.rawValue, model: model, system: system, prompt: prompt, maxTokens: maxTokens)
        return withInactivityTimeout(raw, inactivity: inactivity, overall: overall)
    }

    /// Plain words for why a request failed: "Grok didn't respond.", "The request was cancelled."
    func failureText(for error: Error) -> String {
        let name = selected.displayName
        switch error {
        case let t as AITimedOut: return AIFailureText.timedOut(t.kind, provider: name)
        case is CancellationError, LLMError.canceled: return AIFailureText.cancelled
        case let e as LLMError where e.needsSignIn: return AIFailureText.notSignedIn(provider: name)
        default: return error.localizedDescription
        }
    }

    /// Providers other than the selected one that are signed in and usable, for the "Switch model" menu.
    var otherReadyProviders: [AIProviderID] {
        AIProviderID.allCases.filter { $0 != selected && states[$0]?.ready == true }
    }
}
