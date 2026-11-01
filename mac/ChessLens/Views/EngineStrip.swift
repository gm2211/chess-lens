import SwiftUI
import ChessCore

/// One-line live engine readout under the panel header: eval, depth and best line.
/// Click to unfold every MultiPV line; the gear opens the engine settings. On/off lives in the window toolbar.
struct EngineStrip: View {
    @Environment(AppModel.self) private var app
    @AppStorage("engineStripExpanded") private var expanded = false
    @State private var showSettings = false

    var body: some View {
        let lines = liveLines
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                summary(lines)
                transport
                gear
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            if expanded, !lines.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        EngineLineRow(line: line)
                        if line.id != lines.last?.id { Divider().padding(.leading, 14) }
                    }
                }
            }
        }
        .background(Theme.surface)
    }

    private var settings: EngineSettings { app.engine.settings }

    /// The engine's lines for the position on the board, empty while they are stale or the engine is idle.
    private var liveLines: [EngineLine] {
        guard app.engineEnabled, !app.review.running, app.engine.linesFEN == app.position.fen else { return [] }
        if case .failed = app.engine.status { return [] }
        return app.engine.lines
    }

    @ViewBuilder
    private func summary(_ lines: [EngineLine]) -> some View {
        if case .failed(let why) = app.engine.status {
            status("exclamationmark.triangle", why, color: Theme.blund)
        } else if !app.engine.isAvailable || !app.engineEnabled {
            status("cpu", "Engine off. Turn it on in the toolbar.")
        } else if app.review.running {
            status("hourglass", "Live analysis resumes when the review ends.")
        } else if let end = app.game.gameEnd(at: app.currentID) {
            status("flag.checkered", end.title)
        } else if let best = lines.first {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 8)
                    EvalChip(eval: best.eval, compact: true)
                    Text(app.engine.pauseReason == nil ? "d\(best.depth)" : pausedText(depth: best.depth)).font(.mono(11.5, weight: .regular)).foregroundStyle(Theme.ink3)
                    Text(best.text).font(.mono(12.5)).foregroundStyle(Theme.ink2)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the other engine lines" : "Show all engine lines (\(statText))")
            .accessibilityLabel("Engine: \(best.eval.display), depth \(best.depth), \(best.text)")
        } else if app.engine.pauseReason != nil {
            status("pause.circle", pausedText(depth: nil))
        } else {
            HStack(spacing: 8) {
                Color.clear.frame(width: 8, height: 20)
                RoundedRectangle(cornerRadius: 3).fill(Theme.line).frame(width: 50, height: 20)
                RoundedRectangle(cornerRadius: 3).fill(Theme.line).frame(height: 10)
            }
            .opacity(0.6)
            .accessibilityLabel("Engine is thinking")
        }
    }

    private func status(_ symbol: String, _ text: String, color: Color = Theme.ink3) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .frame(minHeight: 22)
        .help(text)
    }

    /// "Paused" / "Paused — Mac is hot" while analysis is stopped for the position on the board.
    private func pausedText(depth: Int?) -> String {
        switch app.engine.pauseReason {
        case .cool(let r)?: depth.map { "\(r.message) \u{00B7} d\($0)" } ?? r.message
        case .budget?:
            ["Done", depth.map { "d\($0)" }, EngineConfig.budgetLabel(settings.config.budgetSeconds)]
                .compactMap { $0 }.joined(separator: " \u{00B7} ")
        case .inactive?: depth.map { "Paused \u{2014} window not active \u{00B7} d\($0)" } ?? "Paused \u{2014} window not active"
        default: depth.map { "Paused at d\($0)" } ?? "Paused"
        }
    }

    /// Stop while searching, Continue while paused.
    @ViewBuilder
    private var transport: some View {
        if app.engineEnabled, app.engine.isAvailable, !app.review.running, app.game.gameEnd(at: app.currentID) == nil {
            if app.engine.pauseReason == .budget {
                Button { app.engine.keepThinking() } label: {
                    Label("Keep thinking", systemImage: "play.fill").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .help("Analyse this position for another \(EngineConfig.budgetLabel(settings.config.budgetSeconds).lowercased())")
            } else if app.engine.pauseReason == .inactive {
                EmptyView()
            } else if app.engine.pauseReason != nil {
                Button { app.engine.resume() } label: {
                    Label("Continue", systemImage: "play.fill").font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .help("Continue analysing this position")
            } else if app.engine.searching {
                Button { app.engine.pause() } label: {
                    Image(systemName: "pause.fill").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.ink2).frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Stop analysing this position and keep the lines")
                .accessibilityLabel("Pause analysis")
            }
        }
    }

    private var gear: some View {
        Button { showSettings.toggle() } label: {
            Image(systemName: "gearshape").font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.borderless)
        .help("Engine settings: \(footerText)")
        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
            EngineSettingsForm(settings: settings).padding(16).frame(width: 330)
        }
    }

    private var footerText: String {
        let c = settings.config
        let lines = "\(c.lines) line\(c.lines == 1 ? "" : "s")"
        return "\(lines), \(c.threads) thread\(c.threads == 1 ? "" : "s")"
    }

    private var statText: String {
        guard app.engineEnabled, app.engine.depth > 0 else { return "" }
        let nps = app.engine.nps
        let speed = nps >= 1_000_000 ? String(format: "%.1fM n/s", Double(nps) / 1e6) : "\(nps / 1000)k n/s"
        return "depth \(app.engine.depth) · \(speed)"
    }
}

/// The eval in a chip shaded for the side it favours.
private struct EvalChip: View {
    let eval: Eval
    var compact = false

    var body: some View {
        let whiteBetter = eval.whiteWinPercent >= 50
        Text(eval.display)
            .font(.mono(compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(whiteBetter ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.945, green: 0.953, blue: 0.94))
            .frame(minWidth: compact ? 48 : 58)
            .padding(.vertical, compact ? 3 : 6).padding(.horizontal, compact ? 4 : 6)
            .background(whiteBetter ? Theme.barW : Theme.barB, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(whiteBetter ? Theme.line2 : .clear, lineWidth: 1))
    }
}

private struct EngineLineRow: View {
    @Environment(AppModel.self) private var app
    let line: EngineLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            EvalChip(eval: line.eval)
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
        .padding(.horizontal, 14).padding(.vertical, 8)
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
