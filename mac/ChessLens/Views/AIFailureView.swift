import SwiftUI

/// What every AI surface (lesson card, moment note, Ask drawer) shows when a request failed or timed out: the reason
/// in plain words, then Try again and a menu to switch to another signed-in model. Switching retries on its own
/// (see `AppModel.aiSelectionChanged`), so the menu is the whole fix when a provider is down.
struct AIFailureView: View {
    let message: String
    var showsRetry = true
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.blund)
                Text(message).font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if showsRetry { Button("Try again", action: retry).buttonStyle(QuietButtonStyle()) }
                SwitchModelMenu()
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Menu of the other signed-in providers; picking one makes it the selected provider.
struct SwitchModelMenu: View {
    var body: some View {
        let hub = AIHub.shared
        let others = hub.otherReadyProviders
        Menu {
            if others.isEmpty {
                Text("No other model is signed in")
            }
            ForEach(others) { p in
                Button(p.displayName) { hub.selected = p; Task { await hub.refresh(p) } }
            }
        } label: {
            Text("Switch model").font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Use another AI model; this request starts over with it")
    }
}
