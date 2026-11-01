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

/// A ring left where a dropped alternative engine arrow would have pointed; `rank` is that line's engine rank.
struct RingMark: Equatable {
    var square: Square
    var rank: Int
    var opacity: Double
}

/// Draws arrows lichess-style: one filled path per arrow (shaft and head together), knight moves as L shapes,
/// alternatives first so the main move sits on top. Targets whose arrow would overlap a better one get a ring
/// numbered with the engine line's rank, drawn after the arrows so it stays readable.
enum ArrowPainter {
    /// Ring radius in squares.
    static let ringRadius = 0.21

    /// Arrows in priority order (best first); `rings` are targets of dropped overlapping alternatives.
    static func draw(_ ctx: inout GraphicsContext, arrows: [BoardArrow], rings: [RingMark] = [], geo g: BoardGeometry) {
        var paths: [Path] = []
        for a in arrows.reversed() {
            guard let path = path(for: a, geo: g) else { continue }
            paths.append(path)
            let color = a.kind == .threat ? Theme.blund : a.kind == .lesson ? Theme.lesson : Theme.arrow
            var layer = ctx
            layer.opacity = a.opacity
            layer.fill(path, with: .color(color), style: FillStyle(eoFill: false))
        }
        for ring in rings { drawRing(&ctx, ring, under: paths, geo: g) }
    }

    /// The arrow's filled outline (shaft, head and round start cap), nil when it is too short to draw.
    static func path(for a: BoardArrow, geo g: BoardGeometry) -> Path? {
        let p0 = g.center(a.from), p1 = g.center(a.to)
        guard let shape = ArrowGeometry.shape(
            from: ArrowPoint(x: p0.x, y: p0.y), to: ArrowPoint(x: p1.x, y: p1.y), cell: g.cell,
            primary: a.primary, knight: ArrowGeometry.isKnightMove(from: a.from, to: a.to)) else { return nil }
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
        return path
    }

    /// A ring with the line's rank inside. Where a kept arrow runs under it, a board-coloured disc keeps the number readable.
    private static func drawRing(_ ctx: inout GraphicsContext, _ ring: RingMark, under paths: [Path], geo g: BoardGeometry) {
        let c = g.center(ring.square), r = g.cell * ringRadius
        let disc = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let probes = [c] + (0..<8).map { i -> CGPoint in
            let t = Double(i) / 8 * 2 * .pi
            return CGPoint(x: c.x + r * cos(t), y: c.y + r * sin(t))
        }
        if paths.contains(where: { path in probes.contains { path.contains($0) } }) {
            ctx.fill(Path(ellipseIn: disc), with: .color(Sq.isLight(ring.square) ? Theme.sqL : Theme.sqD))
        }
        var layer = ctx
        layer.opacity = ring.opacity
        layer.stroke(Path(ellipseIn: disc.insetBy(dx: g.cell * 0.025, dy: g.cell * 0.025)), with: .color(Theme.arrow), lineWidth: g.cell * 0.05)
        let label = Text("\(ring.rank)").font(.system(size: g.cell * 0.25, weight: .medium, design: .rounded)).foregroundColor(Theme.arrow)
        layer.draw(layer.resolve(label), at: c, anchor: .center)
    }
}
