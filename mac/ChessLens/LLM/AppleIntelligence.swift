import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model (FoundationModels, macOS 26+). No sidecar, no account, nothing leaves the Mac.
/// The framework is weak-linked (project.yml) and only touched behind `#available`, so the app still runs on macOS 14.
enum AppleIntelligence {
    struct Availability: Equatable {
        var ready: Bool
        /// Why it is unavailable, in words for the user. Nil when ready.
        var reason: String?
    }

    static let unsupportedOS = "Apple Intelligence needs macOS 26 or later."

    static func availability() -> Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return Availability(ready: true)
            case .unavailable(let why):
                switch why {
                case .deviceNotEligible: return Availability(ready: false, reason: "This Mac doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return Availability(ready: false, reason: "Turn on Apple Intelligence in System Settings.")
                case .modelNotReady: return Availability(ready: false, reason: "The on-device model is still downloading. Try again soon.")
                @unknown default: return Availability(ready: false, reason: "Apple Intelligence is unavailable.")
                }
            }
        }
        #endif
        return Availability(ready: false, reason: unsupportedOS)
    }

    /// Streams the answer as text chunks (the framework yields cumulative snapshots; this yields only the new part).
    static func stream(system: String, prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26, *) {
                let task = Task {
                    do {
                        let session = system.isEmpty ? LanguageModelSession() : LanguageModelSession(instructions: system)
                        var options = GenerationOptions()
                        if let maxTokens { options.maximumResponseTokens = maxTokens }
                        var sent = ""
                        for try await snapshot in session.streamResponse(to: prompt, options: options) {
                            let full = snapshot.content
                            if full.hasPrefix(sent) {
                                let delta = String(full.dropFirst(sent.count))
                                if !delta.isEmpty { continuation.yield(delta) }
                                sent = full
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: LLMError.canceled)
                    } catch {
                        continuation.finish(throwing: LLMError.server(code: "unavailable", message: "Apple Intelligence could not answer (\(error.localizedDescription))."))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: LLMError.server(code: "unavailable", message: unsupportedOS))
        }
    }
}
