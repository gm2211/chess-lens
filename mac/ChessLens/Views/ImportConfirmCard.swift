import SwiftUI
import ChessCore

/// Dimmed backdrop plus a small card asking whether to load what was just dropped on the window.
struct ImportConfirmCard: View {
    @Environment(AppModel.self) private var app
    /// Width of the side panel, so the card centres on the board column.
    var inspectorWidth: CGFloat = 0

    var body: some View {
        if let pending = app.pendingImport {
            ZStack {
                Theme.scrim
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { app.cancelPendingImport() }
                HStack(spacing: 0) {
                    card(pending)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Color.clear.frame(width: inspectorWidth).allowsHitTesting(false)
                }
            }
            .transition(.opacity)
            .accessibilityAddTraits(.isModal)
        }
    }

    private func card(_ p: PendingImport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            preview(p)
                .frame(width: 280, height: 280)
                .frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.display(21)).foregroundStyle(Theme.ink).lineLimit(2)
                if case .failed(let why) = p.status {
                    Notice(kind: .error, text: why)
                } else if !p.detail.isEmpty {
                    Text(p.detail).font(.system(size: 13)).foregroundStyle(Theme.ink3).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { app.cancelPendingImport() }
                    .buttonStyle(QuietButtonStyle())
                    .keyboardShortcut(.cancelAction)
                switch p.status {
                case .working:
                    EmptyView()
                case .failed:
                    if p.edit != nil {
                        Button("Open editor") { app.editPendingImport() }
                            .buttonStyle(PrimaryButtonStyle())
                            .keyboardShortcut(.defaultAction)
                    }
                case .ready:
                    if p.edit != nil {
                        Button("Edit\u{2026}") { app.editPendingImport() }.buttonStyle(QuietButtonStyle())
                    }
                    Button("Load") { app.confirmPendingImport() }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }

    @ViewBuilder
    private func preview(_ p: PendingImport) -> some View {
        switch p.status {
        case .ready:
            MiniBoard(board: p.previewBoard, flipped: p.flipped, uncertain: p.draft?.uncertain ?? [])
        case .working(let label):
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text(label).font(.system(size: 13.5)).foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30)).foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
        }
    }
}
