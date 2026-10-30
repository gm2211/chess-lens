import AppKit
import Foundation

/// Contact sheet: one row per piece set (all 12 glyphs on a mid-grey background) for visual inspection.
func setSheet(lila: String, out: String) throws {
    let names = trainingSetNames + [heldOutSetName]
    let cell = 64
    let ctx = makeContext(12 * cell, names.count * cell)
    ctx.setFillColor(CGColor(gray: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 12 * cell, height: names.count * cell))
    for (r, name) in names.enumerated() {
        let set = try loadPieceSet(named: name, lilaPieceDir: lila)
        var cov: [String] = []
        for code in pieceCodes {
            let c2 = makeContext(64, 64)
            c2.draw(set.images[code]!, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            let d = c2.data!.assumingMemoryBound(to: UInt8.self)
            var n = 0
            for i in 0..<(64 * 64) where d[i * 4 + 3] > 30 { n += 1 }
            cov.append("\(n * 100 / 4096)")
        }
        print(name, "alpha coverage %:", cov.joined(separator: " "))
        for (c, code) in pieceCodes.enumerated() {
            ctx.draw(set.images[code]!, in: CGRect(x: c * cell, y: (names.count - 1 - r) * cell, width: cell, height: cell))
        }
    }
    try writePNG(ctx.makeImage()!, to: URL(fileURLWithPath: out))
    print(names)
}
