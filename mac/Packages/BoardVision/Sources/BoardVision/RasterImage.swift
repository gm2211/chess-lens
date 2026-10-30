import CoreGraphics
import Foundation

/// An 8-bit RGB raster used for analysis (downscaled copy of the screenshot).
struct RasterImage: Sendable {
    let width: Int
    let height: Int
    /// RGBA, 4 bytes per pixel (alpha ignored), row-major, origin top-left.
    let rgba: [UInt8]
    /// Rec. 601 luma, 0...255.
    let gray: [Float]
    /// Working-resolution pixels per original pixel.
    let scale: Double

    init?(_ image: CGImage, maxDimension: Int) {
        let w0 = image.width, h0 = image.height
        guard w0 > 0, h0 > 0 else { return nil }
        let scale = min(1.0, Double(maxDimension) / Double(max(w0, h0)))
        let w = max(1, Int((Double(w0) * scale).rounded())), h = max(1, Int((Double(h0) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let count = w * h * 4
        let buf = UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: count)
        let bytes = Array(buf)
        var gray = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            gray[i] = 0.299 * Float(bytes[i * 4]) + 0.587 * Float(bytes[i * 4 + 1]) + 0.114 * Float(bytes[i * 4 + 2])
        }
        self.width = w
        self.height = h
        self.rgba = bytes
        self.gray = gray
        self.scale = Double(w) / Double(w0)
    }
}
