// Headless check of the LLM sidecar under the real App Sandbox. Not part of the app target.
// Run via mac/scripts/check-sidecar-sandbox.sh, which swaps this in as the executable of a copy of the built app,
// signs it with the app's entitlements and runs it. Uses the real LLMSidecar.swift.
import Foundation

func say(_ s: String) { print(s); fflush(stdout) }
func tryIt<T>(_ label: String, _ body: () async throws -> T) async -> T? {
    do { let v = try await body(); say("PASS \(label): \(v)"); return v }
    catch { say("FAIL \(label): \(error)"); return nil }
}

let sidecar = LLMSidecar()
_ = await tryIt("status (signed out expected)") { try await sidecar.status() }
_ = await tryIt("keychain write/read/delete from sandboxed child") { try await sidecar.keychainWorks() }

// Loopback listener + browser URL: start sign-in, hit the callback with a bad state, expect a clean auth failure.
let sem = Task { () -> String in
    do {
        _ = try await sidecar.signIn { url in
            say("PASS sign-in URL produced: \(url.host ?? "?")\(url.path)")
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value
            say("redirect_uri: \(redirect ?? "nil")")
            if let redirect, let cb = URL(string: redirect + "?state=bad") {
                Task {
                    do {
                        let (d, r) = try await URLSession.shared.data(from: cb)
                        say("PASS loopback callback reachable: HTTP \((r as? HTTPURLResponse)?.statusCode ?? -1) \(String(decoding: d, as: UTF8.self))")
                    } catch { say("FAIL loopback callback: \(error)") }
                }
            }
        }
        return "signed in?!"
    } catch { return "ended with: \(error)" }
}
say("signIn \(await sem.value)")

_ = await tryIt("complete while signed out (expect reconnect-required)") {
    var out = ""
    do { for try await c in sidecar.complete(system: "s", prompt: "p") { out += c } } catch { return "error: \(error)" }
    return out
}

await sidecar.shutdown()
_ = await tryIt("status after shutdown (restart)") { try await sidecar.status() }
await sidecar.shutdown()
