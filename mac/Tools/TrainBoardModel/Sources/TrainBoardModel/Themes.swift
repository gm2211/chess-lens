import CoreGraphics
import Foundation

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    mutating func uniform(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo + (hi - lo) * CGFloat(Double(next() >> 11) / Double(1 << 53))
    }
    mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
}

struct RGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
    }
    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: alpha) }
    func shifted(_ d: CGFloat) -> RGB { RGB(min(1, max(0, r + d)), min(1, max(0, g + d)), min(1, max(0, b + d))) }
    static func hsv(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> RGB {
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return RGB(v, t, p)
        case 1: return RGB(q, v, p)
        case 2: return RGB(p, v, t)
        case 3: return RGB(p, q, v)
        case 4: return RGB(t, p, v)
        default: return RGB(v, p, q)
        }
    }
}

enum Texture { case flat, wood, grain, glossy }

struct Theme {
    var name: String
    var light: RGB
    var dark: RGB
    var texture: Texture
}

/// Hand-picked themes modelled on lichess / chess.com / common stream overlays.
let baseThemes: [Theme] = [
    Theme(name: "lichess-brown", light: RGB(hex: 0xF0D9B5), dark: RGB(hex: 0xB58863), texture: .flat),
    Theme(name: "lichess-blue", light: RGB(hex: 0xDEE3E6), dark: RGB(hex: 0x8CA2AD), texture: .flat),
    Theme(name: "green", light: RGB(hex: 0xEEEED2), dark: RGB(hex: 0x769656), texture: .flat),
    Theme(name: "purple", light: RGB(hex: 0xF0F1F0), dark: RGB(hex: 0x8877B7), texture: .flat),
    Theme(name: "ic", light: RGB(hex: 0xECECEC), dark: RGB(hex: 0xC1C18E), texture: .flat),
    Theme(name: "grey", light: RGB(hex: 0xD9D9D9), dark: RGB(hex: 0x8E8E8E), texture: .flat),
    Theme(name: "high-contrast", light: RGB(hex: 0xF4F4F4), dark: RGB(hex: 0x4A4A4A), texture: .flat),
    Theme(name: "dark", light: RGB(hex: 0x7A7A7A), dark: RGB(hex: 0x3A3A3A), texture: .flat),
    Theme(name: "chesscom-brown", light: RGB(hex: 0xEDD6B0), dark: RGB(hex: 0xB88762), texture: .glossy),
    Theme(name: "chesscom-wood", light: RGB(hex: 0xE3C99B), dark: RGB(hex: 0xA97A4F), texture: .wood),
    Theme(name: "light-wood", light: RGB(hex: 0xEBD3A7), dark: RGB(hex: 0xA87B4C), texture: .wood),
    Theme(name: "pale-wood", light: RGB(hex: 0xE4CFA4), dark: RGB(hex: 0x946B3E), texture: .wood),
    Theme(name: "marble", light: RGB(hex: 0xE9E6E2), dark: RGB(hex: 0x7B8794), texture: .grain),
    Theme(name: "orange", light: RGB(hex: 0xFAE3B4), dark: RGB(hex: 0xD99853), texture: .flat),
    Theme(name: "red", light: RGB(hex: 0xF3DCDA), dark: RGB(hex: 0xBE6B6B), texture: .flat),
    Theme(name: "teal", light: RGB(hex: 0xD4E7DF), dark: RGB(hex: 0x5E9488), texture: .flat),
    Theme(name: "newspaper", light: RGB(hex: 0xFFFFFF), dark: RGB(hex: 0xBBBBBB), texture: .grain),
    Theme(name: "sand", light: RGB(hex: 0xF1E6C8), dark: RGB(hex: 0xC9B58A), texture: .grain),
]

/// Held out of training (and of the random-theme generator): used only by held-out evaluation and tests.
let heldOutTheme = Theme(name: "rose", light: RGB(hex: 0xF2D9DE), dark: RGB(hex: 0xC48A9A), texture: .flat)

func randomTheme(_ rng: inout SplitMix64) -> Theme {
    if rng.chance(0.55) {
        var t = rng.pick(baseThemes)
        // Small colour jitter so named themes are covered by a neighbourhood, not a single point.
        let dl = rng.uniform(-0.05, 0.05), dd = rng.uniform(-0.06, 0.06)
        t.light = t.light.shifted(dl)
        t.dark = t.dark.shifted(dd)
        return t
    }
    // Random hue pair, excluding the pink range reserved for the held-out theme.
    var h: CGFloat
    repeat { h = rng.uniform(0, 1) } while h > 0.88 && h < 0.98
    let h2 = rng.chance(0.7) ? h : fmod(h + rng.uniform(-0.08, 0.08) + 1, 1)
    let sat = rng.uniform(0.05, 0.55)
    let light = RGB.hsv(h2, rng.uniform(0.0, 0.25), rng.uniform(0.82, 0.98))
    let dark = RGB.hsv(h, sat, rng.uniform(0.42, 0.78))
    let tex: Texture = rng.pick([.flat, .flat, .flat, .wood, .grain, .glossy])
    return Theme(name: "random", light: light, dark: dark, texture: tex)
}

func fillCell(_ ctx: CGContext, rect: CGRect, base: RGB, texture: Texture, rng: inout SplitMix64) {
    ctx.setFillColor(base.shifted(rng.uniform(-0.025, 0.025)).cg())
    ctx.fill(rect)
    ctx.saveGState()
    ctx.clip(to: rect)
    switch texture {
    case .flat:
        break
    case .wood:
        let n = Int(rect.width * 0.9)
        for _ in 0..<n {
            let x = rng.uniform(rect.minX - 2, rect.maxX)
            let w = rng.uniform(0.6, 3.5)
            let d = rng.uniform(-0.10, 0.10)
            ctx.setFillColor(d > 0 ? CGColor(gray: 1, alpha: d) : CGColor(gray: 0, alpha: -d))
            let skew = rng.uniform(-3, 3)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x + w, y: rect.minY))
            ctx.addLine(to: CGPoint(x: x + w + skew, y: rect.maxY))
            ctx.addLine(to: CGPoint(x: x + skew, y: rect.maxY))
            ctx.fillPath()
        }
    case .grain:
        for _ in 0..<Int(rect.width * rect.height / 18) {
            let p = CGPoint(x: rng.uniform(rect.minX, rect.maxX), y: rng.uniform(rect.minY, rect.maxY))
            let d = rng.uniform(-0.07, 0.07)
            ctx.setFillColor(d > 0 ? CGColor(gray: 1, alpha: d) : CGColor(gray: 0, alpha: -d))
            ctx.fill(CGRect(x: p.x, y: p.y, width: rng.uniform(1, 4), height: rng.uniform(1, 4)))
        }
    case .glossy:
        let colors = [CGColor(gray: 1, alpha: 0.10), CGColor(gray: 0, alpha: 0.10)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        }
    }
    ctx.restoreGState()
}
