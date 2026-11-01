import SwiftUI
import ChessCore

struct EvalBar: View {
    var eval: Eval?
    var flipped: Bool        // true when Black is at the bottom
    /// Last real evaluation; held while the next position has none yet so the bar never snaps to the middle.
    @State private var shown: Eval?

    private var whitePct: Double {
        guard let e = shown else { return 50 }
        return min(97, max(3, e.whiteWinPercent))
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let whiteH = h * whitePct / 100
            ZStack(alignment: flipped ? .top : .bottom) {
                Theme.barB
                Theme.barW.frame(height: whiteH)
                if let e = shown {
                    let whiteLeads = e.whiteWinPercent >= 50
                    Text(e.barLabel)
                        .font(.mono(10, weight: .semibold))
                        .foregroundStyle(whiteLeads ? Color(red: 0.106, green: 0.133, blue: 0.125) : Color(red: 0.945, green: 0.953, blue: 0.94))
                        .padding(.vertical, 5)
                        .frame(maxHeight: .infinity, alignment: (whiteLeads != flipped) ? .bottom : .top)
                }
            }
            .frame(width: geo.size.width, height: h)
            .animation(.spring(duration: 0.7, bounce: 0), value: whiteH)
        }
        .onAppear { shown = eval }
        .onChange(of: eval) { _, new in if let new { shown = new } }
        .frame(width: 26)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.barLine, lineWidth: 1))
        .help(shown?.plainDescription ?? "No evaluation yet")
        .accessibilityElement()
        .accessibilityLabel("Evaluation")
        .accessibilityValue(shown?.plainDescription ?? "none")
    }
}
