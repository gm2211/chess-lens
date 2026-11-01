import SwiftUI
import ChessCore

/// One arrow on the board. Emphasis and opacity come from the source (engine rank, review, lesson).
struct BoardArrow: Equatable {
    var from: Square
    var to: Square
    var kind: Kind = .engine
    /// Bold arrow (the main suggestion) versus a slimmer alternative.
    var primary: Bool = true
    var opacity: Double = 0.9
    enum Kind { case engine, best, threat, lesson }
}

/// Draws arrows lichess-style: one filled path per arrow (shaft and head together), knight moves as L shapes,
/// alternatives first so the main move sits on top, and a ring marking targets whose arrow would overlap a better one.
enum ArrowPainter {
    /// Arrows in priority order (best first); `dots` are targets of dropped overlapping alternatives.
    static func draw(_ ctx: inout GraphicsContext, arrows: [BoardArrow], dots: [(Square, Double)] = [], geo g: BoardGeometry) {
        for (sq, opacity) in dots {
            let c = g.center(sq), r = g.cell * 0.17
            var layer = ctx
            layer.opacity = opacity
            layer.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(Theme.arrow), lineWidth: g.cell * 0.05)
        }
        for a in arrows.reversed() {
            let p0 = g.center(a.from), p1 = g.center(a.to)
            guard let shape = ArrowGeometry.shape(
                from: ArrowPoint(x: p0.x, y: p0.y), to: ArrowPoint(x: p1.x, y: p1.y), cell: g.cell,
                primary: a.primary, knight: ArrowGeometry.isKnightMove(from: a.from, to: a.to)) else { continue }
            var path = Path()
            path.addLines(shape.polygon.map { CGPoint(x: $0.x, y: $0.y) })
            path.closeSubpath()
            // The round cap is a polygon wound like the outline, so the union fills solid (opposite windings would cancel).
            let area = zip(shape.polygon, shape.polygon.dropFirst() + [shape.polygon[0]]).reduce(0.0) { $0 + ($1.0.x * $1.1.y - $1.1.x * $1.0.y) }
            let r = shape.capRadius, c = shape.capCenter, sign: Double = area >= 0 ? 1 : -1
            let cap = (0..<24).map { i -> CGPoint in
                let t = sign * Double(i) / 24 * 2 * .pi
                return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
            }
            path.addLines(cap)
            path.closeSubpath()
            let color = a.kind == .threat ? Theme.blund : a.kind == .lesson ? Theme.lesson : Theme.arrow
            var layer = ctx
            layer.opacity = a.opacity
            layer.fill(path, with: .color(color), style: FillStyle(eoFill: false))
        }
    }
}
