import SwiftUI
import AppKit

/// The small tooltip shown when the pointer rests on the target of an engine arrow (or its numbered ring).
struct ArrowHoverLabel: View {
    let text: String

    static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    static let hPad: CGFloat = 8, vPad: CGFloat = 4

    /// The label's size, so the board can clamp it inside its edges.
    static func size(of text: String) -> CGSize {
        let w = (text as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: ceil(w) + hPad * 2, height: ceil(font.ascender - font.descender) + vPad * 2)
    }

    /// Centre of the label for a target square: above the square when there is room, otherwise below,
    /// and always inside the board.
    static func center(size: CGSize, square: CGRect, board: CGFloat) -> CGPoint {
        let gap: CGFloat = 4
        let x = min(max(square.midX, size.width / 2 + 2), board - size.width / 2 - 2)
        let above = square.minY - gap - size.height / 2
        let y = above - size.height / 2 >= 2 ? above : square.maxY + gap + size.height / 2
        return CGPoint(x: x, y: min(y, board - size.height / 2 - 2))
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Self.hPad).padding(.vertical, Self.vPad)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line2, lineWidth: 1))
            .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
