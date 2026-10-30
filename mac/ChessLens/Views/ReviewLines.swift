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
            VStack(alignment: .leading, spacing: 10) {
                if !tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                            Text(t.text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.blund)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.blund.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                        }
                    }
                }
                LineBlock(title: "Threat / refutation", start: id, pos: node.position, pv: entry.pv)
                LineBlock(title: "Better was", start: pid, pos: before, pv: prev.pv,
                          note: "\(prev.eval.display) \u{2192} \(entry.eval.display)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled line of SAN moves; clicking a move plays the line up to it as a variation.
private struct LineBlock: View {
    @Environment(AppModel.self) private var app
    let title: String
    let start: Int
    let pos: Position
    let pv: [String]
    var note: String?

    var body: some View {
        let toks = tokens(pos, pv)
        if !toks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.7).foregroundStyle(Theme.ink3)
                    if let note { Text(note).font(.mono(12)).foregroundStyle(Theme.ink2) }
                    Spacer()
                    Button("Play line") { app.playLine(pv, count: toks.count, from: start) }
                        .buttonStyle(QuietButtonStyle())
                }
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
            }
        }
    }
}
