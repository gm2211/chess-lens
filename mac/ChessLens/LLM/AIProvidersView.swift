import SwiftUI
import AppKit

/// AI provider picker and setup: a provider list with status dots, then the selected provider's sign-in
/// (OAuth button plus a paste-code fallback, or a key field with a setup link, or Apple's availability),
/// model picker and sign out. Popover-friendly (340 pt); used in Settings > AI.
struct AIProvidersView: View {
    var hub: AIHub = .shared

    @State private var key = ""
    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    @State private var pasting = false
    @State private var task: Task<Void, Never>?

    private var id: AIProviderID { hub.selected }
    private var state: AIProviderState { hub.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            list
            Divider().overlay(Theme.line)
            detail
            if let error { Notice(kind: .error, text: error) }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .task { await hub.refresh() }
        .onChange(of: hub.selected) { _, _ in reset() }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 2) {
            ForEach(AIProviderID.allCases) { p in
                let ready = hub.states[p]?.ready == true
                Button { hub.selected = p; Task { await hub.refresh(p) } } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.systemImage).font(.system(size: 12.5)).frame(width: 18).foregroundStyle(Theme.ink2)
                        Text(p.displayName).font(.system(size: 13, weight: p == id ? .semibold : .regular)).foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        Circle().fill(ready ? Theme.good : Theme.ink3.opacity(0.6)).frame(width: 7, height: 7)
                            .help(ready ? "Ready" : "Not set up")
                    }
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(p == id ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(id.displayName).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if busy || hub.signingIn.contains(id) { ProgressView().controlSize(.small) }
            }
            if state.ready { ready } else { setup }
        }
    }

    @ViewBuilder private var ready: some View {
        Text(state.account.map { id.authKind == .oauth ? "Signed in as \($0)" : "Ready: \($0)" } ?? "Ready")
            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
        if id != .apple {
            if state.models.isEmpty {
                Text("No models available.").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            } else {
                Picker("Model", selection: Binding(get: { hub.model }, set: { hub.model = $0 })) {
                    Text("Automatic").tag(String?.none)
                    ForEach(state.models) { Text($0.name).tag(String?.some($0.id)) }
                }
                .font(.system(size: 12.5))
            }
            if let p = state.problem { Text(p).font(.system(size: 12)).foregroundStyle(Theme.ink3) }
            Button("Sign out") { run { await hub.signOut(id) } }.buttonStyle(QuietButtonStyle()).disabled(busy)
        }
    }

    @ViewBuilder private var setup: some View {
        if let p = state.problem { Text(p).font(.system(size: 12)).foregroundStyle(id == .apple ? Theme.ink2 : Theme.blund) }
        switch id.authKind {
        case .onDevice:
            Text(id.setupHint).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            Button("Check again") { run { await hub.refresh(id) } }.buttonStyle(QuietButtonStyle())
        case .oauth: oauth
        case .apiKey: keyField
        case .both:
            oauth
            Text("or").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            keyField
        }
    }

    @ViewBuilder private var oauth: some View {
        if hub.signingIn.contains(id) {
            if let c = hub.deviceCode[id] {
                Text("Enter this code in your browser:").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Text(c).font(.mono(16, weight: .semibold)).foregroundStyle(Theme.ink).textSelection(.enabled)
            } else {
                Text("Finish signing in in your browser.").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            browserLink
            HStack {
                Button("Cancel") { task?.cancel() }.buttonStyle(QuietButtonStyle())
                if id == .claude { Button("Use a code instead") { startPaste() }.buttonStyle(QuietButtonStyle()) }
            }
        } else if hub.awaitingCode.contains(id) || pasting {
            Text("Sign in in your browser, then paste the code it shows.").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            browserLink
            TextField("Code", text: $code).textFieldStyle(.roundedBorder).font(.mono(12))
            HStack {
                Button("Submit") { run { try await hub.submitCode(id, code: code.trimmingCharacters(in: .whitespacesAndNewlines)); reset() } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy || code.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Back") { pasting = false; reset() }.buttonStyle(QuietButtonStyle())
            }
        } else {
            Button("Sign in with \(id.displayName)") { run { try await hub.signIn(id) } }
                .buttonStyle(PrimaryButtonStyle()).disabled(busy)
            if id == .claude {
                Button("Use a code instead") { startPaste() }.buttonStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink2).disabled(busy)
            }
            Text(id.setupHint).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
        }
    }

    /// Fallback for when the browser didn't come up: reopen the sign-in page, or copy it to paste elsewhere.
    @ViewBuilder private var browserLink: some View {
        if let url = hub.signInURL[id] {
            HStack(spacing: 10) {
                Button("Open browser again") { AIHub.openInBrowser(url) }.buttonStyle(.link)
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }.buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        }
    }

    @ViewBuilder private var keyField: some View {
        SecureField("API key", text: $key).textFieldStyle(.roundedBorder)
            .onSubmit(saveKey)
        HStack {
            Button("Save key", action: saveKey).buttonStyle(PrimaryButtonStyle())
                .disabled(busy || key.trimmingCharacters(in: .whitespaces).isEmpty)
            if let url = id.setupURL { Link("Get a key", destination: url).font(.system(size: 12)) }
        }
        if id.authKind == .apiKey { Text(id.setupHint).font(.system(size: 11.5)).foregroundStyle(Theme.ink3) }
        Text("Your key is checked with the provider, then kept in your Keychain.").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
    }

    // MARK: Actions

    private func saveKey() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        run { try await hub.signIn(id, apiKey: k); key = "" }
    }

    /// Switches Claude to the paste-code flow: opens the console page and waits for the code.
    private func startPaste() {
        task?.cancel()
        pasting = true
        run { try await hub.signIn(id, paste: true) }
    }

    private func reset() { error = nil; key = ""; code = ""; pasting = false }

    private func run(_ work: @escaping () async throws -> Void) {
        error = nil
        busy = true
        let provider = id
        task = Task {
            defer { busy = false }
            do { try await work() }
            catch LLMError.canceled {}
            catch is CancellationError {}
            catch { if provider == hub.selected { self.error = error.localizedDescription } }
        }
    }
}
