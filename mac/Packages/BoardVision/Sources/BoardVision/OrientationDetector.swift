import CoreGraphics
import Foundation
import Vision
import CoreML

/// Decides which side is at the bottom of the screenshot.
///
/// Primary signal: coordinate labels (file letters / rank digits) read with Vision OCR in the edge squares or just
/// outside the board. Fallback: where the white and black pieces sit.
enum OrientationDetector {
    struct Votes: Equatable {
        var normal = 0  // a-h left to right, 1-8 bottom to top (White at the bottom)
        var flipped = 0
        var total: Int { normal + flipped }
    }

    /// Mean row of white pieces minus mean row of black pieces (image orientation, row 0 = top).
    /// Positive: white pieces sit lower on screen. nil when one colour is absent.
    static func pieceBalance(_ classes: [Int]) -> Double? {
        var w: [Double] = [], b: [Double] = []
        for (i, c) in classes.enumerated() {
            let row = Double(i / 8)
            if (1...6).contains(c) { w.append(row) } else if (7...12).contains(c) { b.append(row) }
        }
        guard !w.isEmpty, !b.isEmpty else { return nil }
        return w.reduce(0, +) / Double(w.count) - b.reduce(0, +) / Double(b.count)
    }

    static func decide(votes: Votes, balance: Double?) -> Bool {
        let heuristic: Bool? = balance.map { $0 >= 0 }
        if votes.total >= 2 {
            let normalShare = Double(votes.normal) / Double(votes.total)
            let confidentLabels = normalShare >= 0.75 || normalShare <= 0.25
            if confidentLabels {
                let labelsSayNormal = normalShare >= 0.5
                if votes.total >= 3 { return labelsSayNormal }
                if heuristic == nil || abs(balance ?? 0) < 1.0 || heuristic == labelsSayNormal { return labelsSayNormal }
            }
        }
        return heuristic ?? true
    }

    // MARK: OCR

    static func readLabels(_ image: CGImage, geometry g: BoardGeometry) -> Votes {
        var votes = Votes()
        let s = g.side
        func scan(vertical: Bool, near: Bool) {
            // vertical: scan a column of cells expecting rank digits; otherwise a row expecting file letters.
            for k in 0..<8 {
                let cell = vertical ? g.cell(file: near ? 0 : 7, row: k) : g.cell(file: k, row: near ? 7 : 0)
                var region = cell
                let out = 0.45 * s
                if vertical { if near { region.origin.x -= out }; region.size.width += out }
                else { if !near { region.origin.y -= out }; region.size.height += out }
                if !vertical && near { region.size.height += 0 }
                for hit in recognize(image, region: region) {
                    guard hit.box.height >= 0.07 * s, hit.box.height <= 0.45 * s else { continue }
                    let cx = hit.box.midX, cy = hit.box.midY
                    let inside = cell.contains(CGPoint(x: cx, y: cy))
                    if inside {
                        let dx = min(cx - cell.minX, cell.maxX - cx), dy = min(cy - cell.minY, cell.maxY - cy)
                        if dx > 0.4 * s || dy > 0.4 * s { continue }
                    }
                    if vertical {
                        guard let d = digit(from: hit.text, strict: inside) else { continue }
                        if d == 8 - k { votes.normal += 1 } else if d == k + 1 { votes.flipped += 1 }
                    } else {
                        guard let f = letter(from: hit.text) else { continue }
                        if f == k { votes.normal += 1 } else if f == 7 - k { votes.flipped += 1 }
                    }
                    if !vertical && !near { /* top row letters read the same way as the bottom row */ }
                }
                if votes.total >= 6 && (votes.normal == 0 || votes.flipped == 0) { return }
            }
        }
        // Usual places first: left column digits, bottom row letters.
        scan(vertical: true, near: true)
        if votes.total < 6 || (votes.normal > 0 && votes.flipped > 0) { scan(vertical: false, near: true) }
        if votes.total < 3 {
            scan(vertical: true, near: false)
            scan(vertical: false, near: false)
        }
        return votes
    }

    private static func digit(from text: String, strict: Bool) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count == 1, let c = t.first else { return nil }
        if let v = c.wholeNumberValue, (1...8).contains(v) { return v }
        if "lI|".contains(c) { return 1 }
        return nil
    }

    private static func letter(from text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count == 1, let c = t.unicodeScalars.first, c.value >= 97, c.value <= 104 else { return nil }
        return Int(c.value) - 97
    }

    struct Hit { var text: String; var box: CGRect }

    /// OCR on a region of the image; boxes are returned in image pixel coordinates (origin top-left).
    static func recognize(_ image: CGImage, region: CGRect) -> [Hit] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = region.integral.intersection(bounds)
        guard r.width >= 4, r.height >= 4, let sub = image.cropping(to: r) else { return [] }
        // Upscale small crops so label glyphs are comfortably above Vision's minimum text size.
        let k = max(1.0, min(5.0, 220.0 / min(r.width, r.height)))
        let w = Int(r.width * k), h = Int(r.height * k)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(sub, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.05
        // In the App Sandbox the Neural Engine compile service is unreachable and the request blocks forever.
        if let cpu = MLComputeDevice.allComputeDevices.first(where: { if case .cpu = $0 { true } else { false } }),
           let stages = try? request.supportedComputeStageDevices.keys {
            for stage in stages { try? request.setComputeDevice(cpu, for: stage) }
        }
        let handler = VNImageRequestHandler(cgImage: scaled, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        var hits: [Hit] = []
        for obs in request.results ?? [] {
            let b = obs.boundingBox
            let box = CGRect(x: r.minX + b.minX * r.width, y: r.minY + (1 - b.maxY) * r.height, width: b.width * r.width, height: b.height * r.height)
            for cand in obs.topCandidates(3) where cand.string.trimmingCharacters(in: .whitespacesAndNewlines).count == 1 {
                hits.append(Hit(text: cand.string, box: box))
                break
            }
        }
        return hits
    }
}
