import SwiftUI
import AppKit

// MARK: - Empty state — Full Disk Access

/// Card that fills the right pane when bootstrap finishes with 0 workspaces.
///
/// For Claude, the most common cause is macOS not granting Full Disk Access
/// to the binary; for Codex / Gemini it's almost always "the CLI was never
/// installed or hasn't run yet". The copy + the affordances adapt
/// accordingly — only the Claude variant shows the System Settings shortcut,
/// since Codex and Gemini aren't FDA-gated paths in practice.
struct FullDiskAccessEmptyState: View {
    let provider: ProviderID
    let onReload: () async -> Void
    @State private var reloading = false

    private var title: String {
        switch provider {
        case .claude: return "Chronicle can't see your sessions"
        case .codex:  return "No Codex sessions found"
        case .gemini: return "No Gemini sessions found"
        }
    }

    private var bodyText: String {
        switch provider {
        case .claude:
            return """
                macOS hasn't given Chronicle access to read \
                ~/.claude/projects/. Open System Settings → Privacy & \
                Security → Full Disk Access and add Chronicle.
                """
        case .codex:
            return """
                Chronicle didn't find any Codex sessions under \
                ~/.codex/sessions/. Install Codex CLI and run a session, \
                then click Reload.
                """
        case .gemini:
            return """
                Chronicle didn't find any Gemini sessions under \
                ~/.gemini/tmp/. Install Gemini CLI and run a session, \
                then click Reload.
                """
        }
    }

    /// Only Claude's empty state is realistically caused by FDA — for
    /// Codex / Gemini the path is user-readable by default, so the
    /// Privacy Settings shortcut would just be misleading.
    private var showsPrivacyButton: Bool {
        provider == .claude
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(Theme.Font.display(size: 18, wdth: 100, wght: 600, opsz: 24))
                .foregroundStyle(Theme.Color.text)

            Text(bodyText)
                .font(Theme.Font.bodyBase)
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if showsPrivacyButton {
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
                }

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
