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

/// Body of a critical-moment note: why the move was bad (or good) and what was better.
struct MomentDetail: View {
    @Environment(AppModel.self) private var app
    let id: Int

    var body: some View {
        let node = app.game.nodes[id]
        if let entry = app.review.entries[id], let pid = node.parent, let prev = app.review.entries[pid], let move = node.move {
            let before = app.game.nodes[pid].position
            let tags = before.lineTags(played: move, refutation: entry.pv, best: prev.pv, evalAfter: entry.eval)
            let positive = entry.cls.map { !$0.isError } ?? false
            let playedBest = prev.best == move.uci
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
                LineBlock(caption: positive ? "The point" : entry.cls == nil ? "What followed" : "What it allowed",
                          rule: entry.cls.map(Theme.color(for:)) ?? Theme.ink3, start: id, pos: node.position, pv: entry.pv)
                if !playedBest {
                    LineBlock(caption: entry.cls == nil ? "Engine preferred" : "Better was", rule: Theme.good,
                              start: pid, pos: before, pv: prev.pv)
                }
                CommentaryBlock(id: id, positive: positive)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A line of SAN moves with a colored left rule; clicking a move plays the line up to it as a variation.
private struct LineBlock: View {
    @Environment(AppModel.self) private var app
    var caption: String?
    let rule: Color
    let start: Int
    let pos: Position
    let pv: [String]

    var body: some View {
        let toks = tokens(pos, pv)
        if !toks.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
            if let caption {
                Text(caption).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink3)
            }
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
            }
            .padding(.leading, 8)
            .overlay(alignment: .leading) { Rectangle().fill(rule).frame(width: 2) }
        }
    }
}

/// Icon-only Explain and the resulting AI lesson for one moment. Without AI set up it shows nothing:
/// the summary carries the one setup hint.
private struct CommentaryBlock: View {
    @Environment(AppModel.self) private var app
    let id: Int
    let positive: Bool

    var body: some View {
        let ai = app.review.commentary
        let state = ai.states[id]
        let ready = AIHub.shared.isReady
        VStack(alignment: .leading, spacing: 8) {
            switch state {
            case nil where !ready, .needsSignIn? where !ready:
                EmptyView()
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
            case .done(let l, let unverified)?:
                LessonView(lesson: l, positive: positive, unverified: unverified)
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

/// The coach's lesson: the concept as a chip, then short sections with bold lead-ins, the rule of thumb last.
private struct LessonView: View {
    let lesson: MomentLesson
    let positive: Bool
    let unverified: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let c = lesson.concept {
                HStack(spacing: 4) {
                    Image(systemName: "lightbulb").font(.system(size: 10.5, weight: .semibold))
                    Text(c.prefix(1).uppercased() + c.dropFirst()).font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Theme.accentSoft, in: Capsule())
            }
            section("The idea", lesson.idea)
            section(positive ? "What the opponent missed" : "What went wrong", lesson.whatWentWrong)
            section(positive ? "Why it works" : "Better", lesson.betterIdea)
            if let p = lesson.plain {
                Text(p).font(.system(size: 13)).foregroundStyle(Theme.ink2)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let r = lesson.rule {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.good)
                    Text("\(Text(positive ? "Take away" : "Rule of thumb").fontWeight(.semibold).foregroundColor(Theme.ink)) \(r)")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
            if !unverified.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle").font(.system(size: 11))
                    Text("Some moves unverified").font(.system(size: 11.5))
                }
                .foregroundStyle(Theme.ink3)
                .help("Not found in the game or the engine's lines: \(unverified.joined(separator: ", "))")
            }
        }
    }

    @ViewBuilder private func section(_ lead: String, _ text: String?) -> some View {
        if let text {
            Text("\(Text(lead).fontWeight(.semibold).foregroundColor(Theme.ink)) \(text)")
                .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
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
