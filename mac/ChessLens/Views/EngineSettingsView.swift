import SwiftUI

/// The advanced engine form, shared by the Engine panel popover and the Settings window.
struct EngineSettingsForm: View {
    let settings: EngineSettings

    var body: some View {
        let c = settings.config
        VStack(alignment: .leading, spacing: 14) {
            Picker("Strength", selection: Binding(get: { c.preset }, set: { settings.choose($0) })) {
                ForEach(EnginePreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            row("Depth", "How far ahead the engine looks before it stops. Higher is stronger but slower.") {
                Toggle("No limit", isOn: Binding(
                    get: { c.depthCap == 0 },
                    set: { on in settings.edit { $0.depthCap = on ? 0 : EnginePreset.medium.depthCap } }
                ))
                .toggleStyle(.checkbox).font(.system(size: 12))
                Stepper(value: Binding(
                    get: { c.depthCap == 0 ? EnginePreset.medium.depthCap : c.depthCap },
                    set: { v in settings.edit { $0.depthCap = v } }
                ), in: EngineSettings.depthRange) {
                    Text("\(c.depthCap == 0 ? EnginePreset.medium.depthCap : c.depthCap)").font(.mono(13)).frame(minWidth: 22, alignment: .trailing)
                }
                .disabled(c.depthCap == 0)
            }
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
            row("Hash", "Memory for the engine's lookup table. More helps at greater depths.") {
                Picker("Hash", selection: Binding(get: { c.hash }, set: { v in settings.edit { $0.hash = v } })) {
                    ForEach(EngineSettings.hashSizes, id: \.self) { Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
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
