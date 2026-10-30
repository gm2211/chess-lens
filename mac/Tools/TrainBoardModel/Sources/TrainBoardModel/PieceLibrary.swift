import AppKit
import Foundation

/// Names of the 12 piece glyphs, as used in file names and class labels ("wK", "bP", ...).
let pieceCodes = ["wP", "wN", "wB", "wR", "wQ", "wK", "bP", "bN", "bB", "bR", "bQ", "bK"]
/// Class labels: index 0 is the empty square, then the 12 pieces.
let classLabels = ["empty"] + pieceCodes

struct PieceSet {
    let name: String
    let images: [String: CGImage]
}

/// Piece sets whose licenses allow redistribution of derived data in a GPL app (see THIRD_PARTY.md).
/// "chessnut" is held out of training and used for the held-out evaluation / Swift tests.
let trainingSetNames = [
    "cburnett", "merida", "mpchess", "pirouetti", "letter", "pixel", "shapes", "rhosgfx",
    "fantasy", "spatial", "celtic", "kiwen-suwi", "firi", "totoy", "papercut",
]
let heldOutSetName = "chessnut"

/// Fraction of pixels with visible alpha (detects SVGs that CoreSVG silently renders blank).
func alphaCoverage(_ image: CGImage) -> Double {
    let n = 64
    let ctx = makeContext(n, n)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var c = 0
    for i in 0..<(n * n) where d[i * 4 + 3] > 30 { c += 1 }
    return Double(c) / Double(n * n)
}

/// CoreSVG ignores <filter> effects and clip paths and can render such files fully blank; strip them and retry.
func sanitizedSVG(at url: URL) -> NSImage? {
    guard var text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for pattern in ["<filter[\\s\\S]*?</filter>", "<defs>[\\s\\S]*?</defs>", " filter=\"url\\(#[^\"]*\\)\"", " clip-path=\"url\\(#[^\"]*\\)\""] {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return NSImage(data: Data(text.utf8))
}

func renderSVG(at url: URL, size: Int, sanitize: Bool = false) -> CGImage? {
    guard let img = (sanitize ? sanitizedSVG(at: url) : NSImage(contentsOf: url)), img.size.width > 0, img.size.height > 0 else { return nil }
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let aspect = img.size.width / img.size.height
    let w = aspect >= 1 ? CGFloat(size) : CGFloat(size) * aspect
    let h = aspect >= 1 ? CGFloat(size) / aspect : CGFloat(size)
    let rect = NSRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    img.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
}

func loadPieceSet(named name: String, lilaPieceDir: String, size: Int = 256) throws -> PieceSet {
    var images: [String: CGImage] = [:]
    for code in pieceCodes {
        let url = URL(fileURLWithPath: "\(lilaPieceDir)/\(name)/\(code).svg")
        var rendered = renderSVG(at: url, size: size)
        if rendered == nil || alphaCoverage(rendered!) < 0.02 { rendered = renderSVG(at: url, size: size, sanitize: true) }
        guard let img = rendered, alphaCoverage(img) >= 0.02 else {
            throw NSError(domain: "TrainBoardModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot render \(url.path)"])
        }
        images[code] = img
    }
    return PieceSet(name: name, images: images)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "TrainBoardModel", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
    }
    try data.write(to: url)
}
