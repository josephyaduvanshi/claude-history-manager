import SwiftUI
import AppKit

// MARK: - Empty state — Full Disk Access

/// Card that fills the right pane when bootstrap finishes with 0 workspaces.
/// The most common cause is macOS not granting Full Disk Access to the
/// debug binary; there's no clear UI indication of that condition without
/// this card.
struct FullDiskAccessEmptyState: View {
    let onReload: () async -> Void
    @State private var reloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chronicle can't see your sessions")
                .font(Theme.Font.display(size: 18, wdth: 100, wght: 600, opsz: 24))
                .foregroundStyle(Theme.Color.text)

            Text("""
                macOS hasn't given Chronicle access to read \
                ~/.claude/projects/. Open System Settings → Privacy & \
                Security → Full Disk Access and add Chronicle.
                """)
                .font(Theme.Font.bodyBase)
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open Privacy Settings")
                        .font(Theme.Font.btnPrimary)
                        .foregroundStyle(Theme.Color.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)

                Button {
                    Task {
                        reloading = true
                        await onReload()
                        reloading = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if reloading { ProgressView().controlSize(.small) }
                        Text(reloading ? "Reloading…" : "Reload")
                            .font(Theme.Font.btn)
                            .foregroundStyle(Theme.Color.text)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Theme.Color.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(reloading)
            }
        }
        .padding(28)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Theme.Color.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.Color.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.bg)
    }
}
