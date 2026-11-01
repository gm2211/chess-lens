import SwiftUI
import ChessCore

/// A critical moment's note under its move in the annotated game, as one compact row: an accent bar in the
/// move's class color, one sentence (the AI note's first sentence, or the engine's own when the note isn't
/// there yet), a "better ..." chip and a "lines" toggle that opens the played / better lines and the full note.
struct MomentAnnotation: View {
    @Environment(AppModel.self) private var app
    let id: Int

    var body: some View {
        if app.game.nodes.indices.contains(id) { content } else { EmptyView() }
    }

    @ViewBuilder private var content: some View {
        let review = app.review
        let node = app.game.nodes[id]
        let entry = review.entries[id]
        let pid = node.parent
        let prev = pid.flatMap { review.entries[$0] }
        let before = pid.map { app.game.nodes[$0].position }
        let expanded = review.expandedMoments.contains(id)
        let state = review.commentary.states[id]
        let positive = entry?.cls.map { !$0.isError } ?? false
        let sentence = Self.sentence(state: state, positive: positive, node: node, entry: entry, prev: prev, before: before)
        let better = Self.betterChip(node: node, prev: prev, before: before)
        let bar = entry?.cls.map(Theme.color(for:)) ?? Theme.accent
        VStack(alignment: .leading, spacing: 6) {
            sentenceLine(sentence, state: state)
            FlowLayout(spacing: 6, lineSpacing: 4) {
                if let better, let pid {
                    Button { app.playLine(prev?.pv ?? [], count: 1, from: pid) } label: {
                        HStack(spacing: 4) {
                            Text("better").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                            Text(better).font(.mono(12, weight: .semibold)).foregroundStyle(Theme.ink)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.good.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Play the engine's move from here")
                }
                if case .failed(let m)? = state {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.blund)
                        Text("note unavailable \u{00B7}").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                        Button("Retry") { review.commentary.explain(id, game: app.game, review: review) }
                            .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.accent)
                    }
                    .help(m)
                }
                Button { toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text("lines").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Hide the lines and the full note" : "Show what followed, what was better, and the full note")
            }
            if expanded { MomentDetail(id: id).padding(.top, 2) }
        }
        .padding(.vertical, 4).padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(bar).frame(width: 2) }
        .padding(.leading, 44).padding(.trailing, 12).padding(.vertical, 3)
    }

    @ViewBuilder private func sentenceLine(_ text: String?, state: AICommentary.State?) -> some View {
        let loading = state == .loading
        if let text {
            Text(text).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .modifier(Shimmer(active: loading))
        } else if loading {
            Text("\u{2026}").font(.system(size: 12.5)).foregroundStyle(Theme.ink3).modifier(Shimmer(active: true))
        }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) {
            if app.review.expandedMoments.contains(id) { app.review.expandedMoments.remove(id) }
            else { app.review.expandedMoments.insert(id) }
        }
    }

    // MARK: - Content

    /// The note's one sentence: the finished AI lesson's first sentence, else the engine's own tag for the move.
    static func sentence(state: AICommentary.State?, positive: Bool, node: GameNode, entry: ReviewEntry?, prev: ReviewEntry?,
                         before: Position?) -> String? {
        if case .done(let l, _)? = state {
            let order = positive ? [l.idea, l.whatWentWrong, l.plain, l.concept] : [l.whatWentWrong, l.idea, l.plain, l.concept]
            if let s = order.compactMap({ $0 }).first(where: { !$0.isEmpty }) { return firstSentence(s) }
        }
        if let entry, let prev, let before, let move = node.move,
           let t = before.lineTags(played: move, refutation: entry.pv, best: prev.pv, evalAfter: entry.eval).first {
            return t.text.prefix(1).uppercased() + t.text.dropFirst() + "."
        }
        return nil
    }

    /// "6. Qf6" / "6\u{2026}Qf6": the engine's move from the position before the played one, unless it was played.
    static func betterChip(node: GameNode, prev: ReviewEntry?, before: Position?) -> String? {
        guard let prev, let before, let best = prev.best, let move = node.move, best != move.uci,
              let san = before.sanLine(fromUCI: [best], maxPlies: 1).first else { return nil }
        return before.turn == .white ? "\(before.fullmove). \(san)" : "\(before.fullmove)\u{2026}\(san)"
    }

    /// Text up to the first sentence end, with the end kept.
    static func firstSentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var i = t.startIndex
        while i < t.endIndex {
            let c = t[i]
            if ".!?".contains(c) {
                let n = t.index(after: i)
                if n == t.endIndex || t[n].isWhitespace { return String(t[...i]) }
            }
            i = t.index(after: i)
        }
        return t
    }
}

/// A slow pulse on text that is still being written.
private struct Shimmer: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.35 : 1)
            .onAppear { pulse() }
            .onChange(of: active) { _, _ in pulse() }
    }

    private func pulse() {
        if active { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true } }
        else { withAnimation(.default) { dim = false } }
    }
}
