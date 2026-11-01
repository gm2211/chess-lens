import Foundation
import AppKit
import AVFoundation
import Observation
import VoiceKit
import KokoroTTS

/// The voices on this Mac: the installed system voices (re-scanned whenever the app becomes active, so a voice
/// downloaded in System Settings shows up without a restart) and the on-demand Kokoro download.
@Observable @MainActor
final class VoiceLibrary {
    static let shared = VoiceLibrary()

    enum KokoroState: Equatable {
        case notInstalled
        case working(KokoroInstallPhase)
        case installed(bytes: Int64)
    }

    private(set) var systemVoices: [SystemVoiceInfo] = []
    private(set) var kokoro: KokoroState = .notInstalled
    /// Why the last Kokoro download or removal failed, until the next attempt.
    private(set) var kokoroError: String?
    @ObservationIgnored private var installTask: Task<Void, Never>?

    private static var language: String { Locale.preferredLanguages.first ?? "en-US" }

    var bestSystemVoice: SystemVoiceInfo? { SystemVoicePicker.best(systemVoices, preferredLanguage: Self.language) }
    var groupedSystemVoices: [(quality: SystemVoiceInfo.Quality, voices: [SystemVoiceInfo])] {
        SystemVoicePicker.grouped(systemVoices, preferredLanguage: Self.language)
    }
    var premiumVoices: [SystemVoiceInfo] { groupedSystemVoices.first { $0.quality == .premium }?.voices ?? [] }
    var kokoroInstalled: Bool { if case .installed = kokoro { true } else { false } }
    /// A model carried in the app bundle (developer builds) cannot be removed from Settings.
    var kokoroIsBundled: Bool { kokoroInstalled && KokoroRuntime.directory != KokoroRuntime.store.directory }

    private init() {
        rescan()
        KokoroRuntime.store.cleanLeftovers()      // a download the app quit during
        refreshKokoro()
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, AVSpeechSynthesizer.availableVoicesDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in VoiceLibrary.shared.rescan() }
            }
        }
    }

    func rescan() {
        let found = AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoiceInfo(id: $0.identifier, name: $0.name, language: $0.language,
                            quality: SystemVoiceInfo.Quality(rawValue: $0.quality.rawValue) ?? .standard,
                            isNovelty: $0.voiceTraits.contains(.isNoveltyVoice))
        }
        if found != systemVoices { systemVoices = found }
    }

    // MARK: Kokoro

    func downloadKokoro() {
        guard installTask == nil else { return }
        kokoroError = nil
        kokoro = .working(.downloading(received: 0, total: KokoroAsset.v1_0.size))
        installTask = Task {
            do {
                try await KokoroInstaller(store: KokoroRuntime.store).install { phase in
                    Task { @MainActor in VoiceLibrary.shared.report(phase) }
                }
                installTask = nil
                refreshKokoro()
                // Downloaded to be used: switch to it unless another Kokoro voice is already chosen.
                if !NarrationSettings.shared.voice.isKokoro { NarrationSettings.shared.voice = .kokoro(.default) }
                return
            } catch {
                let e = KokoroInstallError.from(error)
                if e != .cancelled { kokoroError = e.errorDescription }
            }
            installTask = nil
            refreshKokoro()
        }
    }

    func cancelKokoro() { installTask?.cancel() }

    func removeKokoro() {
        guard installTask == nil else { return }
        do { try KokoroRuntime.store.remove(); kokoroError = nil } catch {
            kokoroError = "The voice could not be removed: \(error.localizedDescription)"
        }
        refreshKokoro()
    }

    /// Progress hops arrive after `install` returns at the latest; once the task is gone they are ignored.
    private func report(_ phase: KokoroInstallPhase) {
        guard installTask != nil else { return }
        kokoro = .working(phase)
    }

    private func refreshKokoro() {
        KokoroRuntime.refresh()
        if let dir = KokoroRuntime.directory {
            kokoro = .installed(bytes: KokoroStore.diskUsage(dir))
        } else {
            kokoro = .notInstalled
        }
    }

    // MARK: System Settings

    /// Opens System Settings at Accessibility > Spoken Content, where Apple's voices (Ava Premium and others) are
    /// downloaded via System Voice > Manage Voices. Apple does not let apps download system voices themselves.
    /// The anchor is tried first; System Settings ignores an unknown anchor and shows Accessibility, and the legacy
    /// pane id is the last resort.
    static let spokenContentURLs = [
        "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
        "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
        "x-apple.systempreferences:com.apple.preference.universalaccess",
    ]

    static func openSpokenContentSettings() {
        for s in spokenContentURLs {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }
}
