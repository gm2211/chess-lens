import SwiftUI
import ChessCore

/// A critical moment's note, indented under its move in the annotated game: the move, its class and the
/// eval swing, then (unless folded) the AI teaching and the played / better lines. The accent rule and
/// sparkle set it apart from the source's own comments.
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
        let prev = node.parent.flatMap { review.entries[$0] }
        let collapsed = review.collapsedMoments.contains(id)
        let concept: String? = if case .done(let l, _)? = review.commentary.states[id] { l.concept } else { nil }
        VStack(alignment: .leading, spacing: 8) {
            Button { toggle() } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                            .rotationEffect(.degrees(collapsed ? 0 : 90)).frame(width: 8)
                        Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(moveLabel(app.game, id)).font(.mono(12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        if let c = entry?.cls { ClassBadge(cls: c, size: 14).help(c.name.prefix(1).uppercased() + c.name.dropFirst()) }
                        else { TurnBadge(size: 14) }
                        Spacer(minLength: 6)
                        if let prev, let entry {
                            Text("\(prev.eval.display) \u{2192} \(entry.eval.display)")
                                .font(.mono(11.5, weight: .regular)).foregroundStyle(Theme.ink3).lineLimit(1)
                        }
                    }
                    if collapsed, let concept {
                        Text(concept.prefix(1).uppercased() + concept.dropFirst())
                            .font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1).padding(.leading, 30)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(collapsed ? "Show the note on this move" : "Fold the note on this move")
            if !collapsed { MomentDetail(id: id) }
        }
        .padding(.vertical, 7).padding(.leading, 10).padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft.opacity(0.18), in: Rectangle())
        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 2) }
        .padding(.leading, 44).padding(.trailing, 12).padding(.vertical, 4)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) {
            if app.review.collapsedMoments.contains(id) { app.review.collapsedMoments.remove(id) }
            else { app.review.collapsedMoments.insert(id) }
        }
    }
}
