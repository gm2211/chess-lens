import SwiftUI

/// A move-class glyph ("!!", "!", "?!", "?", "??") in a filled circle of the class colour, as used across the review.
struct ClassBadge: View {
    let cls: MoveClass
    var size: CGFloat = 16

    var body: some View {
        Circle().fill(Theme.color(for: cls))
            .frame(width: size, height: size)
            .overlay(
                Text(cls.rawValue)
                    .font(.system(size: size * (cls.rawValue.count > 1 ? 0.5 : 0.62), weight: .heavy, design: .rounded))
                    .tracking(-0.4)
                    .foregroundStyle(.white)
                    .fixedSize()
            )
            .accessibilityLabel(cls.name)
    }
}

/// The badge for a turning point the engine flagged without a move class.
struct TurnBadge: View {
    var size: CGFloat = 16

    var body: some View {
        Circle().fill(Theme.ink3)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "arrow.up.arrow.down").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(Theme.surface))
            .accessibilityLabel("turning point")
            .help("Turning point: the evaluation changed a lot here")
    }
}

/// Badge plus count, e.g. [?! 4], with a tooltip ("4 inaccuracies").
struct ClassCount: View {
    let cls: MoveClass
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            ClassBadge(cls: cls, size: 15)
            Text("\(count)").font(.system(size: 12.5, weight: .regular).monospacedDigit()).foregroundStyle(Theme.ink2)
        }
        .help("\(count) \(cls.plural(count))")
    }
}
