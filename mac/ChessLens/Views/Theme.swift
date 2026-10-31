import SwiftUI
import AppKit

/// Design tokens shared with the web version (see Assets.xcassets/Colors, generated from web/index.html).
enum Theme {
    static let bg = Color("bg")
    static let surface = Color("surface")
    static let surface2 = Color("surface2")
    static let ink = Color("ink")
    static let ink2 = Color("ink2")
    static let ink3 = Color("ink3")
    static let line = Color("line")
    static let line2 = Color("line2")
    static let accent = Color("accent")
    static let accentInk = Color("accentInk")
    static let accentSoft = Color("accentSoft")
    static let sqL = Color("sqL")
    static let sqD = Color("sqD")
    static let hlLast = Color("hlLast")
    static let hlSel = Color("hlSel")
    static let dot = Color("dot")
    static let check = Color("check")
    static let arrow = Color("arrow")
    static let barW = Color("barW")
    static let barB = Color("barB")
    static let barLine = Color("barLine")
    static let good = Color("good")
    static let inacc = Color("inacc")
    static let mist = Color("mist")
    static let blund = Color("blund")
    static let scrim = Color("scrim")

    /// Positive classes ("!" great, "!!" brilliant). Not in the shared web palette yet, so defined here.
    static let great = adaptive(light: (0.30, 0.50, 0.71), dark: (0.45, 0.64, 0.84))
    static let brilliant = adaptive(light: (0.07, 0.58, 0.56), dark: (0.20, 0.72, 0.69))

    static func color(for cls: MoveClass) -> Color {
        switch cls {
        case .blunder: blund
        case .mistake: mist
        case .inaccuracy: inacc
        case .great: great
        case .brilliant: brilliant
        }
    }

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

extension Font {
    /// Display face: New York (system serif), standing in for Instrument Serif.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .regular, design: .serif) }
    static func mono(_ size: CGFloat, weight: Weight = .medium) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .padding(.horizontal, 14).frame(minHeight: 30)
            .foregroundStyle(Theme.accentInk)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 5))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 11).frame(minHeight: 28)
            .foregroundStyle(Theme.ink)
            .background(configuration.isPressed ? Theme.surface2 : Theme.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct Notice: View {
    enum Kind { case info, error, ok, warn }
    var kind: Kind = .info
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(kind == .info ? Theme.ink2 : (kind == .warn ? Theme.ink : color))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(kind == .info ? Theme.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(kind == .info ? Theme.line : color, lineWidth: 1))
    }

    private var color: Color {
        switch kind {
        case .error: Theme.blund
        case .ok: Theme.good
        case .warn: Theme.inacc
        case .info: Theme.line
        }
    }
}

/// Simple wrapping layout for move lists. Subviews flagged `fullWidth` take a whole line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 1
    var lineSpacing: CGFloat = 3

    struct FullWidthKey: LayoutValueKey { static let defaultValue = false }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        return arrange(width: w, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, f) in result.frames.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let full = s[FullWidthKey.self]
            var size = s.sizeThatFits(full ? ProposedViewSize(width: width, height: nil) : .unspecified)
            if full { size.width = width }
            if (x > 0 && x + size.width > width) || (full && x > 0) {
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineH = max(lineH, size.height)
            maxX = max(maxX, x - spacing)
            if full { x = 0; y += lineH + lineSpacing; lineH = 0 }
        }
        let total = (frames.last.map { $0.maxY } ?? 0)
        return (CGSize(width: width.isFinite ? width : maxX, height: total), frames)
    }
}

extension View {
    func fullWidthInFlow(_ on: Bool = true) -> some View { layoutValue(key: FlowLayout.FullWidthKey.self, value: on) }
}
