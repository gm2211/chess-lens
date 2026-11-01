import SwiftUI

/// The engine form (lines, threads, memory, cool-down), shared by the engine strip popover and the Settings window.
struct EngineSettingsForm: View {
    let settings: EngineSettings

    var body: some View {
        let c = settings.config
        VStack(alignment: .leading, spacing: 14) {
            row("Lines", "How many alternative moves to show, best first.") {
                Stepper(value: Binding(get: { c.lines }, set: { v in settings.edit { $0.lines = v } }), in: EngineSettings.lineRange) {
                    Text("\(c.lines)").font(.mono(13)).frame(minWidth: 22, alignment: .trailing)
                }
            }
            row("Threads", "CPU cores used for analysis. More is faster but runs hotter and drains the battery.") {
                Stepper(value: Binding(get: { c.threads }, set: { v in settings.edit { $0.threads = v } }), in: EngineSettings.threadRange) {
                    Text("\(c.threads)").font(.mono(13)).frame(minWidth: 22, alignment: .trailing)
                }
            }
            row("Memory", "Memory for the engine's lookup table. More helps at greater depths.") {
                Picker("Hash", selection: Binding(get: { c.hash }, set: { v in settings.edit { $0.hash = v } })) {
                    ForEach(EngineSettings.hashSizes, id: \.self) { Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            row("Pause when the Mac is hot or in Low Power Mode", "Analysis stops by itself to cool the Mac down and resumes when it has.") {
                Toggle("", isOn: Binding(get: { c.pauseWhenHot }, set: { v in settings.edit { $0.pauseWhenHot = v } }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
        }
    }

    private func row<C: View>(_ title: String, _ help: String, @ViewBuilder control: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
                control()
            }
            Text(help).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
