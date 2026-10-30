import Accelerate
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Side length (px) of every training image; the Swift recognizer resamples square crops to the same size.
let sampleSize = 64
/// Extra context around the square, as a fraction of the square side, on each side.
let cropMargin: CGFloat = 0.06

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func drawText(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat, color: CGColor, fontName: String?, bold: Bool) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let font = fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
    (text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? NSColor.black])
    NSGraphicsContext.restoreGraphicsState()
}

func jpegRoundTrip(_ image: CGImage, quality: CGFloat) -> CGImage {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return image }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest), let src = CGImageSourceCreateWithData(data, nil),
          let out = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return image }
    return out
}

struct SampleRenderer {
    let sets: [PieceSet]
    let themes: (inout SplitMix64) -> Theme
    let S: CGFloat = 64

    // MARK: overlays

    private func highlight(_ ctx: CGContext, _ r: CGRect, _ rng: inout SplitMix64) {
        let palette: [(RGB, CGFloat)] = [
            (RGB(hex: 0x9BC700), 0.41),  // lichess last move
            (RGB(hex: 0xF6F669), 0.75), (RGB(hex: 0xBACA2B), 0.8),  // chess.com
            (RGB(hex: 0xFFAA00), 0.45), (RGB(hex: 0xE0A020), 0.7),  // orange (stream overlays)
            (RGB(hex: 0x4F8CFF), 0.4), (RGB(hex: 0x14551E), 0.3), (RGB(hex: 0xFFFF00), 0.35),
            (RGB(hex: 0xCC4444), 0.35),
        ]
        if rng.chance(0.75) {
            let (c, a) = rng.pick(palette)
            ctx.setFillColor(c.cg(a * rng.uniform(0.8, 1.2)))
        } else {
            ctx.setFillColor(RGB.hsv(rng.uniform(0, 1), rng.uniform(0.4, 1), rng.uniform(0.6, 1)).cg(rng.uniform(0.25, 0.7)))
        }
        ctx.fill(r)
    }

    private func checkGlow(_ ctx: CGContext, _ r: CGRect, _ rng: inout SplitMix64) {
        let a = rng.uniform(0.5, 1)
        let colors = [CGColor(srgbRed: 1, green: 0, blue: 0, alpha: a), CGColor(srgbRed: 0.9, green: 0, blue: 0, alpha: a * 0.7),
                      CGColor(srgbRed: 0.6, green: 0, blue: 0, alpha: 0)] as CFArray
        guard let g = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 0.25, 0.9]) else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: r.midX, y: r.midY), startRadius: 0,
                               endCenter: CGPoint(x: r.midX, y: r.midY), endRadius: r.width * 0.72, options: [])
        ctx.restoreGState()
    }

    private func coordinate(_ ctx: CGContext, _ r: CGRect, isLight: Bool, theme: Theme, _ rng: inout SplitMix64) {
        let text = rng.chance(0.5) ? String(UnicodeScalar(UInt8(97 + rng.int(8)))) : String(1 + rng.int(8))
        let size = r.width * rng.uniform(0.15, 0.24)
        let other = isLight ? theme.dark : theme.light
        let color: CGColor = rng.chance(0.7) ? other.cg(rng.uniform(0.7, 1)) : CGColor(gray: rng.chance(0.5) ? 0.15 : 0.9, alpha: rng.uniform(0.5, 0.9))
        let font = rng.pick([nil, "Helvetica-Bold", "ArialMT", "Verdana-Bold", "Menlo-Regular", "Avenir-Heavy", "TrebuchetMS"])
        let m = r.width * 0.05
        let corner = rng.int(4)
        let w = size * 0.62 * CGFloat(text.count), h = size * 1.1
        let x = (corner % 2 == 0) ? r.minX + m : r.maxX - m - w
        let y = (corner < 2) ? r.maxY - m - h : r.minY + m
        drawText(ctx, text, at: CGPoint(x: x, y: y), size: size, color: color, fontName: font, bold: true)
    }

    private func marker(_ ctx: CGContext, _ r: CGRect, hasPiece: Bool, _ rng: inout SplitMix64) {
        if hasPiece {
            // Capture ring around the square corners.
            ctx.setStrokeColor(CGColor(srgbRed: 0.08, green: 0.33, blue: 0, alpha: rng.uniform(0.25, 0.4)))
            ctx.setLineWidth(r.width * 0.1)
            ctx.strokeEllipse(in: r.insetBy(dx: r.width * 0.06, dy: r.height * 0.06))
        } else {
            let rad = r.width * rng.uniform(0.12, 0.2)
            ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.33, blue: 0, alpha: rng.uniform(0.2, 0.4)))
            ctx.fillEllipse(in: CGRect(x: r.midX - rad, y: r.midY - rad, width: rad * 2, height: rad * 2))
        }
    }

    private func arrow(_ ctx: CGContext, canvas: CGFloat, _ rng: inout SplitMix64) {
        let palette = [RGB(hex: 0x15781B), RGB(hex: 0xE68F00), RGB(hex: 0x882020), RGB(hex: 0x003088), RGB(hex: 0xF0C020), RGB(hex: 0x4CAF50)]
        let angle = rng.uniform(0, 2 * .pi)
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        let center = CGPoint(x: canvas / 2 + rng.uniform(-S * 0.3, S * 0.3), y: canvas / 2 + rng.uniform(-S * 0.3, S * 0.3))
        let back = rng.uniform(S * 0.8, S * 2)
        let fwd = rng.chance(0.4) ? rng.uniform(S * 0.2, S * 0.5) : rng.uniform(S * 0.8, S * 2)  // sometimes ends inside the cell
        let p0 = CGPoint(x: center.x - dir.x * back, y: center.y - dir.y * back)
        let p1 = CGPoint(x: center.x + dir.x * fwd, y: center.y + dir.y * fwd)
        let width = S * rng.uniform(0.12, 0.26)
        let head = width * rng.uniform(2.0, 3.0)
        let color = rng.pick(palette).cg(rng.uniform(0.5, 0.85))
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.butt)
        ctx.beginPath()
        ctx.move(to: p0)
        ctx.addLine(to: CGPoint(x: p1.x - dir.x * head * 0.7, y: p1.y - dir.y * head * 0.7))
        ctx.strokePath()
        let normal = CGPoint(x: -dir.y, y: dir.x)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: p1.x + dir.x * head * 0.3, y: p1.y + dir.y * head * 0.3))
        ctx.addLine(to: CGPoint(x: p1.x - dir.x * head * 0.7 + normal.x * head * 0.55, y: p1.y - dir.y * head * 0.7 + normal.y * head * 0.55))
        ctx.addLine(to: CGPoint(x: p1.x - dir.x * head * 0.7 - normal.x * head * 0.55, y: p1.y - dir.y * head * 0.7 - normal.y * head * 0.55))
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()
    }

    private func cursor(_ ctx: CGContext, canvas: CGFloat, _ rng: inout SplitMix64) {
        let o = CGPoint(x: canvas / 2 + rng.uniform(-S * 0.5, S * 0.4), y: canvas / 2 + rng.uniform(-S * 0.2, S * 0.5))
        let k = S * rng.uniform(0.006, 0.011) * 2
        let pts = [(0, 0), (0, -17), (4, -13), (7.5, -21), (10.5, -19.5), (7, -12), (12, -12)].map {
            CGPoint(x: o.x + CGFloat($0.0) * k, y: o.y + CGFloat($0.1) * k)
        }
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: pts[0])
        pts.dropFirst().forEach { ctx.addLine(to: $0) }
        ctx.closePath()
        ctx.setFillColor(CGColor(gray: rng.chance(0.7) ? 1 : 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: rng.chance(0.7) ? 0 : 1, alpha: 1))
        ctx.setLineWidth(max(1, k * 0.7))
        ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }

    private func caption(_ ctx: CGContext, cell: CGRect, _ rng: inout SplitMix64) {
        // Subtitle-like dark boxes (one or two stacked lines) with large white text, or a faint watermark.
        if rng.chance(0.7) {
            let words = ["hey hey get him", "curity bro", "nice", "lol", "what a move", "no way", "security", "he blundered", "gg", "check", "brilliant"]
            let lines = rng.chance(0.5) ? 2 : 1
            let h = cell.height * rng.uniform(0.3, 0.6)
            var y = cell.minY + rng.uniform(-0.2, 0.7) * cell.height
            let x = cell.minX - rng.uniform(0.2, 1.2) * cell.width
            let font = rng.pick([nil, "Helvetica", "ArialMT", "Verdana", "Avenir-Book", "Roboto-Regular"])
            for _ in 0..<lines {
                let r = CGRect(x: x, y: y, width: cell.width * rng.uniform(1.0, 2.6), height: h)
                ctx.setFillColor(CGColor(gray: rng.uniform(0, 0.15), alpha: rng.uniform(0.65, 0.95)))
                ctx.fill(r)
                drawText(ctx, rng.pick(words), at: CGPoint(x: r.minX + 3, y: r.minY - h * 0.08), size: h * 0.85, color: CGColor(gray: 1, alpha: 1), fontName: font, bold: rng.chance(0.3))
                y -= h * rng.uniform(0.95, 1.1)
            }
        } else {
            drawText(ctx, rng.pick(["TightKnights", "chess", "LIVE", "@kings"]), at: CGPoint(x: cell.minX - S * 0.3, y: cell.minY + rng.uniform(0, cell.height * 0.6)),
                     size: cell.height * rng.uniform(0.3, 0.5), color: CGColor(gray: 1, alpha: rng.uniform(0.15, 0.35)), fontName: nil, bold: true)
        }
    }

    // MARK: composition

    func render(label: Int, rng: inout SplitMix64, pieceSet fixedSet: PieceSet? = nil, theme fixedTheme: Theme? = nil) -> CGImage {
        let canvasSide = Int(S) * 3
        let ctx = makeContext(canvasSide, canvasSide)
        ctx.interpolationQuality = .high
        let theme = fixedTheme ?? themes(&rng)
        let set = fixedSet ?? rng.pick(sets)
        let centerLight = rng.chance(0.5)

        func cell(_ cx: Int, _ cy: Int) -> CGRect { CGRect(x: CGFloat(cx) * S, y: CGFloat(cy) * S, width: S, height: S) }
        func isLight(_ cx: Int, _ cy: Int) -> Bool { ((cx + cy) % 2 == 0) == centerLight }

        for cy in 0..<3 {
            for cx in 0..<3 {
                fillCell(ctx, rect: cell(cx, cy), base: isLight(cx, cy) ? theme.light : theme.dark, texture: theme.texture, rng: &rng)
            }
        }

        // Pieces on the neighbours (only their edges end up inside the crop margin).
        var neighbourPieces: [(Int, Int, String)] = []
        for cy in 0..<3 {
            for cx in 0..<3 where !(cx == 1 && cy == 1) && rng.chance(0.45) {
                neighbourPieces.append((cx, cy, rng.pick(pieceCodes)))
            }
        }

        // Highlights, check glow, coordinates, move markers on the target and sometimes neighbours.
        let centerRect = cell(1, 1)
        let isKing = label == 6 || label == 12
        let highlightP = 0.30
        for cy in 0..<3 {
            for cx in 0..<3 {
                let r = cell(cx, cy)
                let isCenter = cx == 1 && cy == 1
                if rng.chance(isCenter ? highlightP : 0.18) { highlight(ctx, r, &rng) }
                if isCenter, rng.chance(isKing ? 0.2 : (label == 0 ? 0.01 : 0.02)) { checkGlow(ctx, r, &rng) }
                if rng.chance(isCenter ? 0.22 : 0.15) { coordinate(ctx, r, isLight: isLight(cx, cy), theme: theme, &rng) }
            }
        }
        if rng.chance(0.08) { marker(ctx, centerRect, hasPiece: label != 0, &rng) }

        // Pieces.
        let pad = rng.uniform(0.0, 0.14)
        let shadow = rng.chance(0.35)
        let mirrored = rng.chance(0.12)
        func drawPiece(_ code: String, in r: CGRect) {
            guard var img = set.images[code] else { return }
            if rng.chance(0.6) { img = jitterColors(img, white: code.hasPrefix("w"), &rng) }
            ctx.saveGState()
            if rng.chance(0.5) {
                // Mild geometric variation to mimic unseen piece styles.
                ctx.translateBy(x: r.midX, y: r.midY)
                ctx.rotate(by: rng.uniform(-0.06, 0.06))
                ctx.scaleBy(x: rng.uniform(0.9, 1.1), y: rng.uniform(0.9, 1.1))
                ctx.translateBy(x: -r.midX, y: -r.midY)
            }
            if shadow {
                ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.025), blur: S * 0.05, color: CGColor(gray: 0, alpha: 0.4))
            }
            if mirrored {
                ctx.translateBy(x: r.midX, y: 0)
                ctx.scaleBy(x: -1, y: 1)
                ctx.translateBy(x: -r.midX, y: 0)
            }
            ctx.draw(img, in: r.insetBy(dx: r.width * pad / 2, dy: r.height * pad / 2))
            ctx.restoreGState()
        }
        for (cx, cy, code) in neighbourPieces { drawPiece(code, in: cell(cx, cy)) }
        if label > 0 { drawPiece(classLabels[label], in: centerRect) }

        if rng.chance(0.15) { arrow(ctx, canvas: CGFloat(canvasSide), &rng) }
        if rng.chance(0.05) { cursor(ctx, canvas: CGFloat(canvasSide), &rng) }
        if rng.chance(0.07) { caption(ctx, cell: centerRect, &rng) }

        guard let canvas = ctx.makeImage() else { fatalError("canvas") }

        // Crop window: the square plus margin, with scale and offset jitter.
        let scale = 1 + rng.uniform(-0.06, 0.06)
        let win = S * (1 + 2 * cropMargin) * scale
        let ox = rng.uniform(-0.06, 0.06) * S, oy = rng.uniform(-0.06, 0.06) * S
        let crop = CGRect(x: canvas.width.cg / 2 - win / 2 + ox, y: canvas.height.cg / 2 - win / 2 + oy, width: win, height: win)

        // Native-resolution stage (degradation happens here, like a real screenshot), then resample to sampleSize.
        let degrade = rng.chance(0.65)
        let native = degrade ? Int(rng.uniform(34, 80)) : Int(rng.uniform(80, 200))
        let nctx = makeContext(native, native)
        nctx.interpolationQuality = .high
        let sx = CGFloat(native) / win
        nctx.scaleBy(x: sx, y: sx)
        nctx.draw(canvas, in: CGRect(x: -crop.minX, y: -crop.minY, width: CGFloat(canvas.width), height: CGFloat(canvas.height)))
        var stage = nctx.makeImage()!

        if degrade {
            if rng.chance(0.3) { stage = blurred(stage, radius: Int(rng.uniform(1, 3.5))) }
            if rng.chance(0.5) { stage = noisy(stage, sigma: rng.uniform(1, 7), &rng) }
            if rng.chance(0.75) { stage = jpegRoundTrip(stage, quality: rng.uniform(0.2, 0.9)) }
        }
        stage = colorAdjusted(stage, &rng)

        let octx = makeContext(sampleSize, sampleSize)
        octx.interpolationQuality = .high
        octx.draw(stage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        return octx.makeImage()!
    }

    // MARK: pixel post-processing

    /// Random per-channel gain / bias on a premultiplied piece bitmap (cream whites, bluish blacks, flatter contrast...).
    private func jitterColors(_ img: CGImage, white: Bool, _ rng: inout SplitMix64) -> CGImage {
        let n = 128
        let ctx = makeContext(n, n)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return img }
        let base = rng.uniform(0.82, 1.08)
        let gain = [base * rng.uniform(0.93, 1.07), base * rng.uniform(0.93, 1.07), base * rng.uniform(0.93, 1.07)]
        // Black pieces may be lightened to dark grey, white pieces darkened to cream/grey, but never swap polarity.
        let bias = white ? rng.uniform(-0.18, 0.04) : rng.uniform(-0.04, 0.18)
        let bpr = ctx.bytesPerRow
        for y in 0..<n {
            for x in 0..<n {
                let i = y * bpr + x * 4
                let a = CGFloat(data[i + 3])
                for c in 0..<3 {
                    let v = CGFloat(data[i + c]) * gain[c] + bias * a
                    data[i + c] = UInt8(max(0, min(a, v)))
                }
            }
        }
        return ctx.makeImage() ?? img
    }

    private func blurred(_ img: CGImage, radius: Int) -> CGImage {
        let src = makeContext(img.width, img.height)
        src.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let dst = makeContext(img.width, img.height)
        guard let sd = src.data, let dd = dst.data else { return img }
        var sb = vImage_Buffer(data: sd, height: vImagePixelCount(img.height), width: vImagePixelCount(img.width), rowBytes: src.bytesPerRow)
        var db = vImage_Buffer(data: dd, height: vImagePixelCount(img.height), width: vImagePixelCount(img.width), rowBytes: dst.bytesPerRow)
        let k = UInt32(radius * 2 + 1)
        _ = vImageTentConvolve_ARGB8888(&sb, &db, nil, 0, 0, k, k, nil, vImage_Flags(kvImageEdgeExtend))
        return dst.makeImage() ?? img
    }

    private func noisy(_ img: CGImage, sigma: CGFloat, _ rng: inout SplitMix64) -> CGImage {
        let ctx = makeContext(img.width, img.height)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return img }
        let bpr = ctx.bytesPerRow
        for y in 0..<img.height {
            for x in 0..<img.width {
                let n = Int(rng.uniform(-sigma, sigma) * 1.7)
                for c in 0..<3 {
                    let i = y * bpr + x * 4 + c
                    data[i] = UInt8(max(0, min(255, Int(data[i]) + n)))
                }
            }
        }
        return ctx.makeImage() ?? img
    }

    private func colorAdjusted(_ img: CGImage, _ rng: inout SplitMix64) -> CGImage {
        let ctx = makeContext(img.width, img.height)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return img }
        let bpr = ctx.bytesPerRow
        let contrast = rng.uniform(0.85, 1.15), bright = rng.uniform(-14, 14)
        let gain = [rng.uniform(0.96, 1.04), rng.uniform(0.96, 1.04), rng.uniform(0.96, 1.04)]
        for y in 0..<img.height {
            for x in 0..<img.width {
                for c in 0..<3 {
                    let i = y * bpr + x * 4 + c
                    let v = ((CGFloat(data[i]) - 128) * contrast + 128 + bright) * gain[c]
                    data[i] = UInt8(max(0, min(255, v)))
                }
            }
        }
        return ctx.makeImage() ?? img
    }
}

extension Int { var cg: CGFloat { CGFloat(self) } }
