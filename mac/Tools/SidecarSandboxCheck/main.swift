// Headless check of the LLM sidecar under the real App Sandbox. Not part of the app target.
// Run via mac/scripts/check-sidecar-sandbox.sh, which swaps this in as the executable of a copy of the built app,
// signs it with the app's entitlements and runs it. Uses the real LLMSidecar.swift. No real sign-in, no keys.
import Foundation

func say(_ s: String) { print(s); fflush(stdout) }
func tryIt<T>(_ label: String, _ body: () async throws -> T) async -> T? {
    do { let v = try await body(); say("PASS \(label): \(v)"); return v }
    catch { say("FAIL \(label): \(error)"); return nil }
}

let sidecar = LLMSidecar()
let expected = ["chatgpt", "claude", "claudeAPI", "openrouter", "grok", "groq", "huggingface"]

// `providers`: metadata for every provider.
let infos = await tryIt("providers") { try await sidecar.providers() } ?? []
say((infos.map(\.id) == expected ? "PASS" : "FAIL") + " provider ids: \(infos.map(\.id))")
for i in infos { say("  \(i.id): \(i.name), \(i.authKind), flow=\(i.flow.isEmpty ? "-" : i.flow), setup=\(i.setupURL.isEmpty ? "-" : i.setupURL)") }

// `status` for each provider: signed out, no network needed.
for id in expected {
    if let s = await tryIt("status \(id) (signed out expected)", { try await sidecar.status(provider: id) }) {
        say((s.ready ? "FAIL" : "PASS") + " \(id) not ready, models=\(s.models.count)")
    }
}
do { _ = try await sidecar.status(provider: "nope"); say("FAIL unknown provider accepted") }
catch let e as LLMError { if case .server(let c, _) = e, c == "bad-request" { say("PASS unknown provider rejected") } else { say("FAIL unknown provider: \(e)") } }

_ = await tryIt("keychain write/read/delete from sandboxed child") { try await sidecar.keychainWorks() }

// Loopback listener + browser URL: start sign-in, hit the callback with a bad state, expect a clean auth failure.
func loopbackCheck(_ provider: String) async {
    let r = await Task { () -> String in
        do {
            _ = try await sidecar.signIn(provider: provider) { url, _ in
                say("PASS \(provider) sign-in URL produced: \(url.host ?? "?")\(url.path)")
                let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value
                say("  redirect_uri: \(redirect ?? "nil")")
                if let redirect, let cb = URL(string: redirect + "?state=bad&code=x") {
                    Task {
                        do {
                            let (d, r) = try await URLSession.shared.data(from: cb)
                            say("PASS \(provider) loopback callback reachable: HTTP \((r as? HTTPURLResponse)?.statusCode ?? -1) \(String(decoding: d, as: UTF8.self))")
                        } catch { say("FAIL \(provider) loopback callback: \(error)") }
                    }
                }
            }
            return "signed in?!"
        } catch { return "ended with: \(error)" }
    }.value
    say("\(provider) signIn \(r)")
}
await loopbackCheck("chatgpt")
await loopbackCheck("claude")

// Claude paste fallback: URL for the console redirect, then a code with the wrong state is rejected.
do {
    let s = try await sidecar.signIn(provider: "claude", paste: true) { url, _ in
        let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value
        say((redirect == "https://console.anthropic.com/oauth/code/callback" ? "PASS" : "FAIL") + " claude paste URL redirect: \(redirect ?? "nil")")
    }
    say((s.awaitingCode ? "PASS" : "FAIL") + " claude paste awaitingCode=\(s.awaitingCode)")
    do { _ = try await sidecar.submitCode(provider: "claude", code: "abc#wrong-state"); say("FAIL wrong-state code accepted") }
    catch { say("PASS wrong-state code rejected: \(error)") }
} catch { say("FAIL claude paste flow: \(error)") }

// A key provider with nothing stored asks for setup, without touching the network.
_ = await tryIt("complete while not set up (expect reconnect-required)") {
    var out = ""
    do { for try await c in sidecar.complete(provider: "groq", system: "s", prompt: "p") { out += c } } catch { return "error: \(error)" }
    return out
}

await sidecar.shutdown()
_ = await tryIt("status after shutdown (restart)") { try await sidecar.status(provider: "chatgpt") }
await sidecar.shutdown()
