import SwiftUI
import ChessCore

/// Small static or editable board used by the import sheets.
struct MiniBoard: View {
    var board: [Piece?]
    var flipped: Bool = false
    var uncertain: Set<Square> = []
    var onTap: ((Square) -> Void)?
    var onSecondaryTap: ((Square) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let g = BoardGeometry(side: side, flipped: flipped)
            Canvas { ctx, _ in
                for sq in 0..<64 {
                    let r = g.rect(sq)
                    ctx.fill(Path(r), with: .color(Sq.isLight(sq) ? Theme.sqL : Theme.sqD))
                    if let p = board[sq] {
                        ctx.draw(ctx.resolve(Image(p.assetName)), in: r)
                    }
                    if uncertain.contains(sq) {
                        ctx.stroke(Path(r.insetBy(dx: 1.5, dy: 1.5)), with: .color(Theme.blund), lineWidth: 2.5)
                    }
                }
                let fs = max(7, g.cell * 0.2)
                for i in 0..<8 {
                    let file = flipped ? 7 - i : i
                    let bs = Sq.make(file: file, rank: flipped ? 7 : 0)
                    let br = g.rect(bs)
                    ctx.draw(ctx.resolve(Text(String(UnicodeScalar(UInt8(97 + file)))).font(.mono(fs, weight: .semibold)).foregroundColor(Sq.isLight(bs) ? Theme.sqD : Theme.sqL)),
                             at: CGPoint(x: br.maxX - 2, y: br.maxY - 1), anchor: .bottomTrailing)
                    let rank = flipped ? 7 - i : i
                    let ls = Sq.make(file: flipped ? 7 : 0, rank: rank)
                    let lr = g.rect(ls)
                    ctx.draw(ctx.resolve(Text(String(rank + 1)).font(.mono(fs, weight: .semibold)).foregroundColor(Sq.isLight(ls) ? Theme.sqD : Theme.sqL)),
                             at: CGPoint(x: lr.minX + 2, y: lr.minY + 1), anchor: .topLeading)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                if let sq = g.square(at: loc) { onTap?(sq) }
            }
            .overlay {
                if onSecondaryTap != nil {
                    RightClickCatcher { loc in if let sq = g.square(at: loc) { onSecondaryTap?(sq) } }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line2, lineWidth: 1))
    }
}

/// Reports right-clicks (and control-clicks) while letting every other event fall through to the view below.
private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView { CatcherView() }
    func updateNSView(_ v: CatcherView, context: Context) { v.onRightClick = onRightClick }

    final class CatcherView: NSView {
        var onRightClick: ((CGPoint) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let isRight = e.type == .rightMouseDown || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return isRight ? self : nil
        }
        override func rightMouseDown(with event: NSEvent) { report(event) }
        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { report(event) } else { super.mouseDown(with: event) }
        }
        private func report(_ event: NSEvent) { onRightClick?(convert(event.locationInWindow, from: nil)) }
    }
}
