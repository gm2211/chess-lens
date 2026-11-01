import SwiftUI

/// The lesson bar's speaker button: a click mutes or unmutes the narration, its menu picks the voice.
struct NarrationMenu: View {
    let player: LessonPlayer
    private let settings = NarrationSettings.shared

    var body: some View {
        Menu {
            Toggle("Read Aloud", isOn: Binding(get: { player.narrate }, set: { player.narrate = $0 }))
            Divider()
            Picker("Voice", selection: Binding(get: { settings.voice }, set: choose)) {
                ForEach(settings.voices) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
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
        .accessibilityLabel(player.narrate ? "Narration on, \(settings.voice.displayName)" : "Narration muted")
    }

    /// A new voice takes over from the start of the current step.
    private func choose(_ v: NarratorVoice) {
        guard v != settings.voice else { return }
        settings.voice = v
        if player.isPlaying && player.narrate { player.go(to: player.index) }
    }
}

/// Settings > Voice.
struct NarrationSettingsView: View {
    @Bindable private var settings = NarrationSettings.shared
    @State private var sample = VoiceNarrator()
    @State private var playing = false

    var body: some View {
        Form {
            Picker("Lesson voice", selection: $settings.voice) {
                ForEach(settings.voices) { Text($0.displayName).tag($0) }
            }
            Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(playing ? "Stop" : "Play Sample") {
                if playing { sample.stop(); return }
                playing = true
                Task {
                    await sample.speak("After 12. Bxd7, White's bishop pins the knight to the king. Black has to give something back.")
                    playing = false
                }
            }
        }
        .onChange(of: settings.voice) { if playing { sample.stop() } }
        .onDisappear { sample.stop() }
    }

    private var caption: String {
        if case .kokoro = settings.voice {
            return "Kokoro is a neural voice that runs on this Mac; nothing is sent anywhere."
        }
        return KokoroRuntime.isBundled ? "The macOS system voice." : "The macOS system voice (the Kokoro voices are not in this build)."
    }
}
