import SwiftUI
import KokoroTTS
import VoiceKit

/// Which Settings tab is showing (`settings.tab`), so "Get More Voices…" can open Settings at Voice.
enum SettingsTab {
    static let key = "settings.tab"
    static let engine = "engine", ai = "ai", voice = "voice"
}

/// The lesson bar's speaker button: a click mutes or unmutes the narration, its menu picks the voice.
struct NarrationMenu: View {
    let player: LessonPlayer
    private let settings = NarrationSettings.shared
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsTab.key) private var settingsTab = SettingsTab.engine

    var body: some View {
        Menu {
            Toggle("Read Aloud", isOn: Binding(get: { player.narrate }, set: { player.narrate = $0 }))
            Divider()
            Picker("Voice", selection: Binding(get: { settings.effectiveVoice }, set: choose)) {
                ForEach(settings.menuVoices) { Text(settings.displayName($0)).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Get More Voices\u{2026}") {
                settingsTab = SettingsTab.voice
                openSettings()
            }
        } label: {
            Image(systemName: player.narrate ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.ink2)
        } primaryAction: {
            player.narrate.toggle()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .padding(.horizontal, 4)
        .help(player.narrate ? "Mute the narration (menu: choose the voice)" : "Read the lesson aloud (menu: choose the voice)")
        .accessibilityLabel(player.narrate ? "Narration on, \(settings.displayName(settings.effectiveVoice))" : "Narration muted")
    }

    /// A new voice takes over from the start of the current step.
    private func choose(_ v: NarratorVoice) {
        guard v != settings.effectiveVoice else { return }
        settings.voice = v
        if player.isPlaying && player.narrate { player.go(to: player.index) }
    }
}

/// Settings > Voice: the lesson voice, Apple's free Premium voices (downloaded in System Settings) and the
/// on-demand Kokoro neural voice.
struct NarrationSettingsView: View {
    @Bindable private var settings = NarrationSettings.shared
    private let library = VoiceLibrary.shared
    @State private var sample = VoiceNarrator()
    @State private var playing = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                Picker("Lesson voice", selection: Binding(get: { settings.effectiveVoice }, set: { settings.voice = $0 })) {
                    Text(settings.displayName(.bestSystem)).tag(NarratorVoice.bestSystem)
                    if library.kokoroInstalled {
                        Section("Natural voices (Kokoro)") {
                            ForEach(KokoroVoice.allCases, id: \.self) { Text($0.displayName).tag(NarratorVoice.kokoro($0)) }
                        }
                    }
                    ForEach(library.groupedSystemVoices, id: \.quality) { group in
                        Section("\(group.quality.label) system voices") {
                            ForEach(group.voices) { Text(label($0)).tag(NarratorVoice.system($0.id)) }
                        }
                    }
                }
                HStack {
                    Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(playing ? "Stop" : "Play Sample", action: playSample)
                }
            }

            Section("Apple voices") { appleVoices }
            Section("Natural voice") { kokoroRow }
        }
        .formStyle(.grouped)
        .onChange(of: settings.voice) { if playing { sample.stop() } }
        .onAppear { library.rescan() }
        .onDisappear { sample.stop() }
        .confirmationDialog("Remove the Kokoro voice?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { sample.stop(); library.removeKokoro() }
        } message: {
            Text("This frees \(kokoroBytes) of disk space. You can download it again at any time.")
        }
    }

    private func playSample() {
        if playing { sample.stop(); return }
        playing = true
        Task {
            await sample.speak("After 12. Bxd7, White's bishop pins the knight to the king. Black has to give something back.")
            playing = false
        }
    }

    private var caption: String {
        switch settings.effectiveVoice {
        case .kokoro: "Kokoro runs on this Mac; nothing is sent anywhere."
        case .system(nil): "The best English voice on this Mac. A better one you install is used automatically."
        case .system: "A macOS system voice."
        }
    }

    /// "Daniel (English (United Kingdom))" for voices outside the user's own variant of English.
    private func label(_ v: SystemVoiceInfo) -> String {
        let mine = Locale.preferredLanguages.first ?? "en-US"
        guard v.language != mine, let region = Locale.current.localizedString(forIdentifier: v.language) else { return v.name }
        return "\(v.name) (\(region))"
    }

    // MARK: Apple voices

    @ViewBuilder private var appleVoices: some View {
        let premium = library.premiumVoices
        if let ava = premium.first(where: { $0.name == SystemVoicePicker.recommendedPremium }) ?? premium.first {
            Label("\(ava.displayName) is installed", systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
            if premium.count > 1 {
                Text("Also installed: \(premium.filter { $0 != ava }.map(\.displayName).joined(separator: ", ")).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get Ava (Premium) \u{2014} free from Apple")
                Text("In System Settings \u{203A} Accessibility \u{203A} Spoken Content, choose System Voice \u{203A} Manage Voices\u{2026} and download Ava (Premium) under English. It appears here when you come back to Étude.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Spoken Content Settings\u{2026}") { VoiceLibrary.openSpokenContentSettings() }
        }
        Text(installedSummary).font(.callout).foregroundStyle(.secondary)
    }

    private var installedSummary: String {
        let groups = library.groupedSystemVoices
        guard !groups.isEmpty else { return "No English system voices are installed." }
        return "Installed English voices: " + groups.map { "\($0.voices.count) \($0.quality.label)" }.joined(separator: ", ") + "."
    }

    // MARK: Kokoro

    private var kokoroBytes: String {
        if case .installed(let b) = library.kokoro { return ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        return ByteCountFormatter.string(fromByteCount: KokoroAsset.installedSize, countStyle: .file)
    }

    @ViewBuilder private var kokoroRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Natural voice (Kokoro, ~350 MB download)")
                    Text(kokoroDetail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                kokoroButton
            }
            if case .working(let phase) = library.kokoro { progress(phase) }
            if let error = library.kokoroError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var kokoroDetail: String {
        switch library.kokoro {
        case .installed: library.kokoroIsBundled ? "Included in this build. Voices: Heart, Bella, Emma, Michael."
            : "Installed, \(kokoroBytes) on disk. Voices: Heart, Bella, Emma, Michael."
        case .notInstalled, .working: "A neural voice (Heart, Bella, Emma, Michael) that runs on this Mac. Nothing is sent anywhere."
        }
    }

    @ViewBuilder private var kokoroButton: some View {
        switch library.kokoro {
        case .notInstalled:
            Button(library.kokoroError == nil ? "Download" : "Try Again") { library.downloadKokoro() }
        case .working:
            Button("Cancel") { library.cancelKokoro() }
        case .installed:
            if !library.kokoroIsBundled { Button("Remove\u{2026}") { confirmRemove = true } }
        }
    }

    @ViewBuilder private func progress(_ phase: KokoroInstallPhase) -> some View {
        let mb = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch phase {
        case .downloading(let got, let total):
            ProgressView(value: Double(got), total: Double(max(total, 1))) {
                EmptyView()
            } currentValueLabel: {
                Text("Downloading \(mb(got)) of \(mb(total))")
            }
        case .verifying:
            ProgressView(value: nil as Double?) { EmptyView() } currentValueLabel: { Text("Checking the download\u{2026}") }
        case .unpacking:
            ProgressView(value: nil as Double?) { EmptyView() } currentValueLabel: { Text("Installing\u{2026}") }
        }
    }
}
