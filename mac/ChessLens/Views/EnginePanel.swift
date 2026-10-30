import SwiftUI
import ChessCore

struct EnginePanel: View {
    @Environment(AppModel.self) private var app
    @State private var showSettings = false

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Toggle("Engine", isOn: $app.engineEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 13, weight: .semibold))
                    .disabled(!app.engine.isAvailable)
                Spacer()
                Text(statText).font(.mono(12)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            presetRow
            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            Text("Stockfish 18 (GPLv3), running on your Mac. \(footerText)")
                .font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Theme.surface)
    }

    private var settings: EngineSettings { app.engine.settings }

    private var footerText: String {
        let c = settings.config
        let lines = "\(c.lines) line\(c.lines == 1 ? "" : "s")"
        return c.depthCap == 0 ? "\(lines), no depth limit." : "\(lines), up to depth \(c.depthCap)."
    }

    private var presetRow: some View {
        let custom = settings.config.preset == .custom
        return HStack(spacing: 8) {
            Picker("Strength", selection: Binding<EnginePreset?>(
                get: { custom ? nil : settings.config.preset },
                set: { if let p = $0 { settings.choose(p) } }
            )) {
                ForEach(EnginePreset.easy) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(custom ? Theme.accent : Theme.ink2)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.borderless)
            .help(custom ? "Custom engine settings" : "Engine settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                EngineSettingsForm(settings: settings).padding(16).frame(width: 330)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    private var statText: String {
        guard app.engineEnabled, app.engine.depth > 0 else { return "" }
        let nps = app.engine.nps
        let speed = nps >= 1_000_000 ? String(format: "%.1fM n/s", Double(nps) / 1e6) : "\(nps / 1000)k n/s"
        return "depth \(app.engine.depth) · \(speed)"
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let why) = app.engine.status {
            Notice(kind: .error, text: why).padding(14)
        } else if !app.engineEnabled {
            VStack(spacing: 6) {
                Text("Engine is off").font(.display(20)).foregroundStyle(Theme.ink)
                Text("Turn it on to see the best moves for this position.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            }.padding(24)
        } else if app.review.running {
            VStack(spacing: 6) {
                Text("Reviewing the game").font(.display(20)).foregroundStyle(Theme.ink)
                Text("Live analysis resumes when the review ends.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            }.padding(24)
        } else if app.position.legalMoves().isEmpty {
            VStack(spacing: 6) {
                Text(app.position.isCheck ? "Checkmate" : "Stalemate").font(.display(20)).foregroundStyle(Theme.ink)
                Text("There are no legal moves in this position.").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            }.padding(24)
        } else if app.engine.lines.isEmpty || app.engine.linesFEN != app.position.fen {
            VStack(spacing: 0) {
                ForEach(0..<settings.config.lines, id: \.self) { _ in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.line).frame(width: 58, height: 24)
                        RoundedRectangle(cornerRadius: 3).fill(Theme.line).frame(height: 12)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    Divider()
                }
            }.opacity(0.6)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(app.engine.lines) { line in
                        EngineLineRow(line: line)
                        Divider()
                    }
                }
            }
        }
    }
}

private struct EngineLineRow: View {
    @Environment(AppModel.self) private var app
    let line: EngineLine

    var body: some View {
        let whiteBetter = line.eval.whiteWinPercent >= 50
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(line.eval.display)
                .font(.mono(13, weight: .semibold))
                .foregroundStyle(whiteBetter ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.945, green: 0.953, blue: 0.94))
                .frame(minWidth: 58)
                .padding(.vertical, 6).padding(.horizontal, 6)
                .background(whiteBetter ? Theme.barW : Theme.barB, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(whiteBetter ? Theme.line2 : .clear, lineWidth: 1))
            FlowLayout(spacing: 0, lineSpacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .number(let s):
                        Text(s).font(.mono(12.5)).foregroundStyle(Theme.ink3).padding(.leading, 3)
                    case .move(let san, let index):
                        Button {
                            app.playLine(line.pv, count: index + 1)
                        } label: {
                            Text(san).font(.mono(13.5)).foregroundStyle(Theme.ink)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                        }
                        .buttonStyle(EngineMoveStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private enum Item { case number(String), move(String, Int) }

    private var items: [Item] {
        var out: [Item] = []
        let pos = app.position
        var number = pos.fullmove
        var white = pos.turn == .white
        for (i, san) in line.sanMoves.enumerated() {
            if white { out.append(.number("\(number).")) } else if i == 0 { out.append(.number("\(number)\u{2026}")) }
            out.append(.move(san, i))
            if !white { number += 1 }
            white.toggle()
        }
        return out
    }
}

private struct EngineMoveStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.accentSoft : (hover ? Theme.accentSoft.opacity(0.7) : .clear), in: RoundedRectangle(cornerRadius: 3))
            .onHover { hover = $0 }
    }
}
