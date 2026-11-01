import SwiftUI
import ChessCore

/// Maps squares to points for a board drawn with White (or Black) at the bottom.
struct BoardGeometry {
    var side: CGFloat
    var flipped: Bool
    var cell: CGFloat { side / 8 }

    func rect(_ sq: Square) -> CGRect {
        let f = Sq.file(sq), r = Sq.rank(sq)
        let col = flipped ? 7 - f : f
        let row = flipped ? r : 7 - r
        return CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
    }

    func center(_ sq: Square) -> CGPoint { let r = rect(sq); return CGPoint(x: r.midX, y: r.midY) }

    func square(at p: CGPoint) -> Square? {
        guard p.x >= 0, p.y >= 0, p.x < side, p.y < side else { return nil }
        let col = Int(p.x / cell), row = Int(p.y / cell)
        return Sq.make(file: flipped ? 7 - col : col, rank: flipped ? row : 7 - row)
    }
}

struct BoardView: View {
    @Environment(AppModel.self) private var app
    let side: CGFloat

    @State private var selected: Square?
    @State private var dragFrom: Square?
    @State private var dragPoint: CGPoint = .zero
    @State private var gestureActive = false
    @State private var gestureStartedOnTarget = false
    @State private var wasSelectedAtStart = false
    @State private var promotion: (from: Square, to: Square)?

    private var geo: BoardGeometry { BoardGeometry(side: side, flipped: app.flipped) }

    private var legalFromSelected: [Move] {
        guard let s = selected else { return [] }
        return app.position.legalMoves(from: s)
    }

    /// On a notable reviewed move: the opponent's best reply (threat) and the move that was better.
    private var reviewArrows: [BoardArrow] {
        if app.hidesEvaluation { return [] }
        let review = app.review
        guard review.hasResults, let e = review.entries[app.currentID], e.cls?.isError == true,
              let pid = app.node.parent else { return [] }
        var out: [BoardArrow] = []
        if let m = e.pv.first.flatMap({ Move(uci: $0) }) { out.append(BoardArrow(from: m.from, to: m.to, kind: .threat, opacity: 0.78)) }
        if let m = review.entries[pid]?.best.flatMap({ Move(uci: $0) }) { out.append(BoardArrow(from: m.from, to: m.to, kind: .best, opacity: 0.78)) }
        return out
    }

    /// The summary example being illustrated here, if any (see `AppModel.showExample`).
    private var lessonFocus: LessonFocus? {
        guard !app.hidesEvaluation, let f = app.lessonFocus, f.nodeID == app.currentID else { return nil }
        return f
    }

    /// The lesson step being played, if any: it owns the board (its arrows and circles only, no engine arrows).
    private var lessonStep: GameLesson.StoryStep? {
        guard !app.hidesEvaluation, let p = app.lessonPlayer else { return nil }
        return p.current.step
    }

    /// The arrows to draw (best first) and the targets of overlapping alternatives to mark with a ring.
    private var arrowPlan: (arrows: [BoardArrow], dots: [(Square, Double)]) {
        if app.hidesEvaluation { return ([], []) }
        // The guided review owns the board: its marks only (none while a question is open).
        if let w = app.walkthrough { return (w.marks.arrows, []) }
        if let st = lessonStep {
            return (st.arrows.map { BoardArrow(from: $0.from, to: $0.to, kind: .lesson, opacity: 0.82) }, [])
        }
        // An illustrated example owns the board: only its arrows, so the point isn't lost among engine lines.
        if let f = lessonFocus, !f.arrows.isEmpty || !f.squares.isEmpty {
            return (f.arrows.map { BoardArrow(from: $0.from, to: $0.to, kind: .lesson, opacity: 0.82) }, [])
        }
        var all = reviewArrows
        if app.engineEnabled, app.engine.linesFEN == app.position.fen, !app.review.running {
            let lines = app.engine.lines.sorted { $0.rank < $1.rank }
            if let best = lines.first {
                let mover = app.position.turn
                for l in lines.prefix(3) {
                    guard let u = l.firstMove, let m = Move(uci: u) else { continue }
                    let gap = winPercent(best.eval, for: mover) - winPercent(l.eval, for: mover)
                    if l.rank != best.rank && gap > ArrowGeometry.maxAlternativeGap { continue }
                    if l.rank == best.rank {
                        all.append(BoardArrow(from: m.from, to: m.to, primary: true, opacity: 0.9))
                    } else {
                        all.append(BoardArrow(from: m.from, to: m.to, primary: false, opacity: ArrowGeometry.alternativeOpacity(gap: gap)))
                    }
                }
            }
        }
        // Review arrows come first and win; then the engine's best, then alternatives. Same move twice keeps the first.
        var seen = Set<Int>()
        all = all.filter { seen.insert($0.from * 64 + $0.to).inserted }
        let resolved = ArrowGeometry.resolveOverlaps(all.map { ArrowCandidate(from: $0.from, to: $0.to) })
        let kept = resolved.arrows.compactMap { c in all.first { $0.from == c.from && $0.to == c.to } }
        let dots = resolved.dots.map { sq in (sq, all.first { $0.to == sq }?.opacity ?? 0.4) }
        return (kept, dots)
    }

    var body: some View {
        let g = geo
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in drawBoard(&ctx, g) }
                .frame(width: side, height: side)

            pieceLayer(g)
                .id(app.epoch)

            stateBadgeLayer(g)

            circleLayer(g)

            Canvas { ctx, _ in let plan = arrowPlan; ArrowPainter.draw(&ctx, arrows: plan.arrows, dots: plan.dots, geo: g) }
                .frame(width: side, height: side)
                .allowsHitTesting(false)

            if let promo = promotion { promotionPicker(promo, g) }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .contentShape(Rectangle())
        .gesture(dragGesture(g), isEnabled: promotion == nil)
        .onChange(of: app.currentID) { _, _ in selected = nil; dragFrom = nil; promotion = nil }
        .onChange(of: app.epoch) { _, _ in selected = nil; dragFrom = nil; promotion = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Chess board")
        .accessibilityValue(app.boardPosition.fen)
    }

    // MARK: Layers

    private func pieceLayer(_ g: BoardGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(app.boardPieces()) { inst in
                let dragging = dragFrom == inst.square && gestureActive && dragFrom != nil
                let c = dragging ? dragPoint : g.center(inst.square)
                ZStack {
                    // A promotion cross-fades the pawn into its new piece.
                    Image(inst.piece.assetName)
                        .resizable()
                        .interpolation(.high)
                        .id(inst.piece.assetName)
                        .transition(.opacity)
                }
                    .frame(width: g.cell, height: g.cell)
                    .animation(.easeInOut(duration: 0.25), value: inst.piece.assetName)
                    .scaleEffect(dragging ? 1.12 : 1)
                    .shadow(color: .black.opacity(dragging ? 0.35 : 0), radius: 6, y: 4)
                    .position(c)
                    .zIndex(dragging ? 10 : 1)
                    .transition(.opacity)
                    .animation(dragging ? nil : .easeInOut(duration: previewing ? LessonPlayer.lineMoveAnimation : 0.3), value: inst.square)
            }
        }
        // Captured pieces fade out (and come back in when stepping backwards or when a line preview ends).
        .animation(.easeOut(duration: 0.2), value: app.currentID)
        .animation(.easeOut(duration: 0.2), value: app.lessonPlayer?.linePly)
        .animation(.easeOut(duration: 0.2), value: app.walkthrough?.epoch)
        .frame(width: side, height: side, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// How the game ended at the position on the board (nil while it goes on). A lesson line being acted out
    /// is judged on its own position only (no repetition history).
    private var gameEnd: GameEnd? {
        if let p = app.lessonPreview { return p.position.gameEnd }
        return app.game.gameEnd(at: app.currentID)
    }

    /// Game state drawn on the kings: a "#" on a mated king with a crown on the winner's, a "\u{00BD}" on both
    /// kings of a drawn game (the tooltip says why).
    private func stateBadgeLayer(_ g: BoardGeometry) -> some View {
        let pos = app.boardPosition
        let d = max(15, g.cell * 0.31)
        return ZStack(alignment: .topLeading) {
            if let end = gameEnd {
                ForEach([Side.white, Side.black], id: \.self) { side in
                    if let k = pos.kingSquare(side), let badge = stateBadge(end, side) {
                        let r = g.rect(k)
                        StateBadgeView(badge: badge, diameter: d)
                            .position(x: r.maxX - d * 0.5 - g.cell * 0.02, y: r.minY + d * 0.5 + g.cell * 0.02)
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: gameEnd)
        .frame(width: side, height: side, alignment: .topLeading)
    }

    private func stateBadge(_ end: GameEnd, _ side: Side) -> StateBadge? {
        let name = side == .white ? "White" : "Black"
        switch end {
        case .checkmate(let winner):
            return side == winner
                ? StateBadge(kind: .winner, label: "\(name) wins", help: "Checkmate: \(name) wins")
                : StateBadge(kind: .mated, label: "\(name) king is checkmated", help: "Checkmate: \(name) is mated")
        default:
            return StateBadge(kind: .draw, label: "\(name) king: \(end.title.lowercased())", help: end == .stalemate ? "Stalemate: a draw" : end.title)
        }
    }

    /// A lesson line is being acted out on top of the game position.
    private var previewing: Bool { app.lessonPreview != nil }

    /// Rings around the squares the lesson step talks about, popping in when the step starts.
    private func circleLayer(_ g: BoardGeometry) -> some View {
        let squares = lessonStep?.circles ?? (app.hidesEvaluation ? nil : app.walkthrough?.marks.circles) ?? []
        let epoch = app.lessonPlayer?.stepEpoch ?? app.walkthrough?.epoch ?? 0
        return ZStack(alignment: .topLeading) {
            ForEach(squares, id: \.self) { sq in
                LessonRing(cell: g.cell)
                    .position(g.center(sq))
                    .transition(.scale(scale: 1.7).combined(with: .opacity))
            }
            .id(epoch)
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .animation(.spring(response: 0.42, dampingFraction: 0.62), value: epoch)
        .allowsHitTesting(false)
    }

    private func drawBoard(_ ctx: inout GraphicsContext, _ g: BoardGeometry) {
        let cell = g.cell
        for sq in 0..<64 {
            let r = g.rect(sq)
            ctx.fill(Path(r), with: .color(Sq.isLight(sq) ? Theme.sqL : Theme.sqD))
        }
        // Last move
        if let m = app.boardLastMove {
            ctx.fill(Path(g.rect(m.from)), with: .color(Theme.hlLast))
            ctx.fill(Path(g.rect(m.to)), with: .color(Theme.hlLast))
        }
        // Squares a summary example points at
        for sq in lessonFocus?.squares ?? [] {
            let r = g.rect(sq)
            ctx.fill(Path(r), with: .color(Theme.lesson.opacity(0.32)))
            ctx.stroke(Path(r.insetBy(dx: cell * 0.04, dy: cell * 0.04)), with: .color(Theme.lesson.opacity(0.9)), lineWidth: cell * 0.07)
        }
        if let s = selected { ctx.fill(Path(g.rect(s)), with: .color(Theme.hlSel)) }
        // Check
        let shown = app.boardPosition
        if shown.isCheck, let k = shown.kingSquare(shown.turn) {
            let r = g.rect(k)
            let grad = Gradient(stops: [.init(color: Theme.check, location: 0), .init(color: Theme.check, location: 0.4), .init(color: Theme.check.opacity(0), location: 0.85)])
            ctx.fill(Path(r), with: .radialGradient(grad, center: CGPoint(x: r.midX, y: r.midY), startRadius: 0, endRadius: cell * 0.8))
            if gameEnd?.winner != nil {
                ctx.stroke(Path(r.insetBy(dx: cell * 0.035, dy: cell * 0.035)), with: .color(Theme.blund.opacity(0.9)), lineWidth: cell * 0.06)
            }
        }
        // Coordinates
        let fontSize = max(9, cell * 0.17)
        for i in 0..<8 {
            let file = g.flipped ? 7 - i : i
            let bottomSq = Sq.make(file: file, rank: g.flipped ? 7 : 0)
            let br = g.rect(bottomSq)
            let fLabel = Text(String(UnicodeScalar(UInt8(97 + file)))).font(.mono(fontSize, weight: .semibold))
                .foregroundColor(Sq.isLight(bottomSq) ? Theme.sqD : Theme.sqL)
            ctx.draw(ctx.resolve(fLabel), at: CGPoint(x: br.maxX - cell * 0.12, y: br.maxY - cell * 0.13), anchor: .bottomTrailing)

            let rank = g.flipped ? 7 - i : i
            let leftSq = Sq.make(file: g.flipped ? 7 : 0, rank: rank)
            let lr = g.rect(leftSq)
            let rLabel = Text(String(rank + 1)).font(.mono(fontSize, weight: .semibold))
                .foregroundColor(Sq.isLight(leftSq) ? Theme.sqD : Theme.sqL)
            ctx.draw(ctx.resolve(rLabel), at: CGPoint(x: lr.minX + cell * 0.1, y: lr.minY + cell * 0.08), anchor: .topLeading)
        }
        // Legal move hints
        let dragOver = gestureActive && dragFrom != nil ? g.square(at: dragPoint) : nil
        for m in legalFromSelected where m.promotion == nil || m.promotion == .queen {
            let r = g.rect(m.to)
            let isCapture = app.position.board[m.to] != nil || (app.position.board[m.from]?.type == .pawn && Sq.file(m.from) != Sq.file(m.to))
            if m.to == dragOver {
                ctx.stroke(Path(r.insetBy(dx: cell * 0.03, dy: cell * 0.03)), with: .color(Theme.hlSel), lineWidth: cell * 0.06)
            }
            if isCapture {
                let ring = Path(ellipseIn: r.insetBy(dx: cell * 0.06, dy: cell * 0.06))
                ctx.stroke(ring, with: .color(Theme.dot), lineWidth: cell * 0.09)
            } else {
                let d = cell * 0.3
                ctx.fill(Path(ellipseIn: CGRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)), with: .color(Theme.dot))
            }
        }
    }

    // MARK: Interaction

    private func dragGesture(_ g: BoardGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if !gestureActive {
                    // Touching the board during a lesson ends it, so the move is made on the real position.
                    if app.lessonPlayer != nil { app.closeLesson() }
                    // A guided-review question takes the move as a try (a wrong try's preview clears first).
                    if let w = app.walkthrough {
                        if w.acceptsMove { w.clearAttempt() } else { app.closeLesson() }
                    }
                    gestureActive = true
                    let down = g.square(at: v.startLocation)
                    wasSelectedAtStart = (selected == down)
                    gestureStartedOnTarget = false
                    dragFrom = nil
                    if let down {
                        if let sel = selected, app.position.legalMoves(from: sel).contains(where: { $0.to == down }) {
                            gestureStartedOnTarget = true            // a click on a destination square
                        } else if !app.boardLocked, let p = app.position.piece(at: down), p.color == app.position.turn {
                            selected = down
                            dragFrom = down
                        } else {
                            selected = nil
                        }
                    }
                }
                if dragFrom != nil { dragPoint = v.location }
            }
            .onEnded { v in
                defer { gestureActive = false; dragFrom = nil }
                let up = g.square(at: v.location)
                if gestureStartedOnTarget, let sel = selected, let up {
                    attempt(from: sel, to: up)
                } else if let from = dragFrom {
                    if let up, up != from {
                        if !attempt(from: from, to: up) { /* keep selection so the player can click a target */ }
                    } else if wasSelectedAtStart {
                        selected = nil
                    }
                }
            }
    }

    @discardableResult
    private func attempt(from: Square, to: Square) -> Bool {
        let moves = app.position.legalMoves(from: from).filter { $0.to == to }
        guard !moves.isEmpty else { return false }
        if moves.count > 1 || moves[0].promotion != nil {
            promotion = (from, to)
            return true
        }
        selected = nil
        app.boardMove(moves[0])
        return true
    }

    private func promotionPicker(_ promo: (from: Square, to: Square), _ g: BoardGeometry) -> some View {
        let color = app.position.turn
        let r = g.rect(promo.to)
        let fromTop = r.minY < g.side / 2
        let options: [PieceType] = [.queen, .knight, .rook, .bishop]
        return ZStack(alignment: .topLeading) {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { promotion = nil; selected = nil }
            VStack(spacing: 0) {
                ForEach(fromTop ? options : options.reversed(), id: \.self) { t in
                    Button {
                        let m = Move(from: promo.from, to: promo.to, promotion: t)
                        promotion = nil; selected = nil
                        app.boardMove(m)
                    } label: {
                        Image(Piece(color, t).assetName).resizable().padding(g.cell * 0.04)
                            .frame(width: g.cell, height: g.cell)
                    }
                    .buttonStyle(PromotionButtonStyle())
                    .accessibilityLabel("Promote to \(String(t.letter))")
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .offset(x: r.minX, y: fromTop ? 0 : g.side - g.cell * 4)
        }
        .frame(width: g.side, height: g.side)
    }
}

/// A lesson circle: a soft ring in the lesson colour around a square (a piece or an empty square).
struct LessonRing: View {
    let cell: CGFloat
    var body: some View {
        Circle()
            .strokeBorder(Theme.lesson.opacity(0.92), lineWidth: cell * 0.075)
            .background(Circle().fill(Theme.lesson.opacity(0.12)))
            .shadow(color: Theme.lesson.opacity(0.45), radius: cell * 0.08)
            .frame(width: cell * 0.94, height: cell * 0.94)
    }
}

private struct PromotionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
    }
}


/// A small round marker on a king for the state of the game.
struct StateBadge: Equatable {
    enum Kind { case mated, winner, draw }
    var kind: Kind
    var label: String
    var help: String
}

struct StateBadgeView: View {
    let badge: StateBadge
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: max(1, diameter * 0.08))
            content
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
        .help(badge.help)
        .accessibilityElement()
        .accessibilityLabel(badge.label)
    }

    private var fill: Color {
        switch badge.kind {
        case .mated: Theme.blund
        case .winner: Theme.good
        case .draw: Color(white: 0.42)
        }
    }

    @ViewBuilder private var content: some View {
        switch badge.kind {
        case .mated:
            Text("#").font(.system(size: diameter * 0.66, weight: .heavy, design: .rounded)).foregroundStyle(.white)
        case .winner:
            Image(systemName: "crown.fill").font(.system(size: diameter * 0.5, weight: .bold)).foregroundStyle(.white)
        case .draw:
            Text("\u{00BD}").font(.system(size: diameter * 0.62, weight: .heavy, design: .rounded)).foregroundStyle(.white)
        }
    }
}
