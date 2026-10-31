import SwiftUI
import ChessCore

/// Plies of a line shown in a moment's detail.
private let detailPlies = 6

private struct LineToken: Identifiable {
    var id: Int { ply }
    var ply: Int            // number of plies to play to reach this move
    var number: String?     // "7." or "7\u{2026}" when a move number precedes the move
    var san: String
}

private func tokens(_ pos: Position, _ pv: [String]) -> [LineToken] {
    var out: [LineToken] = []
    var number = pos.fullmove
    var white = pos.turn == .white
    for (i, s) in pos.sanLine(fromUCI: pv, maxPlies: detailPlies).enumerated() {
        out.append(LineToken(ply: i + 1, number: white ? "\(number)." : (i == 0 ? "\(number)\u{2026}" : nil), san: s))
        if !white { number += 1 }
        white.toggle()
    }
    return out
}

/// Expanded body of a critical-moment row: why the move was bad and what was better.
struct MomentDetail: View {
    @Environment(AppModel.self) private var app
    let id: Int

    var body: some View {
        let node = app.game.nodes[id]
        if let entry = app.review.entries[id], let pid = node.parent, let prev = app.review.entries[pid], let move = node.move {
            let before = app.game.nodes[pid].position
            let tags = before.lineTags(played: move, refutation: entry.pv, best: prev.pv, evalAfter: entry.eval)
            VStack(alignment: .leading, spacing: 8) {
                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                            Text(t.text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.blund)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.blund.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
                LineBlock(rule: Theme.blund, start: id, pos: node.position, pv: entry.pv)
                LineBlock(rule: Theme.good, start: pid, pos: before, pv: prev.pv)
                CommentaryBlock(id: id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A line of SAN moves with a colored left rule; clicking a move plays the line up to it as a variation.
private struct LineBlock: View {
    @Environment(AppModel.self) private var app
    let rule: Color
    let start: Int
    let pos: Position
    let pv: [String]

    var body: some View {
        let toks = tokens(pos, pv)
        if !toks.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                FlowLayout(spacing: 4, lineSpacing: 3) {
                    ForEach(toks) { t in
                        HStack(spacing: 3) {
                            if let n = t.number { Text(n).font(.mono(12.5)).foregroundStyle(Theme.ink3) }
                            Button { app.playLine(pv, count: t.ply, from: start) } label: {
                                Text(t.san).font(.mono(13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 3))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if pv.count > toks.count { Text("\u{2026}").font(.mono(13)).foregroundStyle(Theme.ink3) }
                }
                Button { app.playLine(pv, count: toks.count, from: start) } label: {
                    Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Play line")
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(rule).frame(width: 2) }
        }
    }
}

/// Icon-only Explain and the resulting AI commentary for one moment.
private struct CommentaryBlock: View {
    @Environment(AppModel.self) private var app
    let id: Int

    var body: some View {
        let ai = app.review.commentary
        let state = ai.states[id]
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case nil:
                Button { ai.explain(id, game: app.game, review: app.review) } label: {
                    Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                        .frame(width: 28, height: 28)
                        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Explain with AI")
            case .loading?:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking\u{2026}").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                }
            case .text(let t)?:
                Text(t).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            case .needsSignIn?:
                Text("Set up AI in the header to explain moves.").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            case .signingIn?:
                Text("Finish signing in in your browser.").font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            case .failed(let m)?:
                HStack(spacing: 8) {
                    Text(m).font(.system(size: 12.5)).foregroundStyle(Theme.blund).lineLimit(1).truncationMode(.tail)
                    Button("Retry") { ai.explain(id, game: app.game, review: app.review) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Runs explanations for every notable move in turn; becomes "Stop" while running.
struct ExplainAllButton: View {
    @Environment(AppModel.self) private var app
    let ids: [Int]

    var body: some View {
        let ai = app.review.commentary
        if let b = ai.batch {
            Button { ai.cancelAll() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                    Text("\(b.done)/\(b.total)").font(.mono(12))
                }
                .foregroundStyle(Theme.ink2).padding(.horizontal, 8).frame(height: 28)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Stop explaining")
        } else if !ids.isEmpty {
            Button { ai.explainAll(ids, game: app.game, review: app.review) } label: {
                Image(systemName: "sparkles.rectangle.stack").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .frame(width: 28, height: 28)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Explain all with AI")
            .disabled(app.review.running)
        }
    }
}
