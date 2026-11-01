import SwiftUI

/// Header chip: sparkles, status dot, provider name. Click shows `popover()`.
struct AIProviderChip<Popover: View>: View {
    let name: String
    let ready: Bool
    @ViewBuilder var popover: () -> Popover
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12))
                Circle().fill(ready ? Theme.good : Theme.ink3.opacity(0.6)).frame(width: 6, height: 6)
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 10).frame(minWidth: 0, maxWidth: 200, minHeight: 28, maxHeight: 28)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(ready ? "AI ready" : "AI not set up")
        .popover(isPresented: $shown, arrowEdge: .bottom) { popover() }
    }
}
