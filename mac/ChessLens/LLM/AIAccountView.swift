import SwiftUI
import AppKit

/// Compact AI account control: sign-in status, "Sign in with ChatGPT", model picker, sign out.
/// The chosen model id is persisted in UserDefaults under `AIAccountView.modelKey`.
struct AIAccountView: View {
    static let modelKey = "ai.model"

    @AppStorage(AIAccountView.modelKey) private var modelID = ""
    @State private var status: LLMStatus?
    @State private var busy = false
    @State private var signingIn = false
    @State private var error: String?
    @State private var signInTask: Task<Void, Never>?

    var sidecar: LLMSidecar = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(status?.signedIn == true ? Theme.good : Theme.ink3).frame(width: 7, height: 7)
                Text(headline).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                if busy { ProgressView().controlSize(.small) }
            }
            if let status, status.signedIn {
                if status.models.isEmpty {
                    Text(status.modelsError == nil ? "No models available." : "Could not load models.")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                } else {
                    Picker("Model", selection: $modelID) {
                        ForEach(status.models) { Text($0.name).tag($0.id) }
                    }
                    .font(.system(size: 12.5))
                }
                Button("Sign out") { signOut() }.buttonStyle(QuietButtonStyle()).disabled(busy)
            } else if signingIn {
                Text("Finish signing in in your browser.").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Button("Cancel") { signInTask?.cancel() }.buttonStyle(QuietButtonStyle())
            } else {
                Button("Sign in with ChatGPT") { signIn() }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                Text("Uses your ChatGPT plan. Sign-in tokens stay in your Keychain.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
            }
            if let error { Notice(kind: .error, text: error) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.line, lineWidth: 1))
        .task { await refresh() }
    }

    private var headline: String {
        guard let status else { return "AI account" }
        if status.signedIn { return status.account.map { "Signed in as \($0)" } ?? "Signed in" }
        return "Not signed in"
    }

    private func apply(_ s: LLMStatus) {
        status = s
        if s.signedIn, !s.models.contains(where: { $0.id == modelID }) { modelID = s.models.first?.id ?? "" }
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        do { apply(try await sidecar.status()); error = nil } catch { self.error = error.localizedDescription }
    }

    private func signIn() {
        error = nil
        signingIn = true
        signInTask = Task {
            defer { signingIn = false }
            do {
                apply(try await sidecar.signIn { url in
                    DispatchQueue.main.async { _ = NSWorkspace.shared.open(url) }
                })
            } catch LLMError.canceled {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func signOut() {
        busy = true
        Task {
            defer { busy = false }
            do { try await sidecar.signOut(); await refresh() } catch { self.error = error.localizedDescription }
        }
    }
}
