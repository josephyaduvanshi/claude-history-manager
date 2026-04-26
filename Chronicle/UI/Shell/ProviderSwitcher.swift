import SwiftUI

/// Segmented control that switches between Chronicle's available
/// providers (Claude / Codex / Gemini). Renders one button per
/// provider in `state.availableProviders`; tiles for unavailable
/// providers don't appear at all.
///
/// Active button: theme `accent` fill + `onAccent` text.
/// Inactive button: theme `bgElev` background + `textMuted` text.
///
/// Hidden entirely when only one provider is available — there's
/// nothing to switch to.
struct ProviderSwitcher: View {
    @Bindable var state: AppState

    var body: some View {
        if state.availableProviders.count > 1 {
            HStack(spacing: 0) {
                ForEach(state.availableProviders, id: \.self) { id in
                    button(for: id)
                }
            }
            .padding(2)
            .background(Theme.Color.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.Color.ruleStrong, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func button(for id: ProviderID) -> some View {
        let isActive = state.activeProvider == id
        return Button {
            state.switchTo(id)
        } label: {
            HStack(spacing: 5) {
                ProviderIconView(id: id, size: 11)
                Text(id.displayName)
                    .font(Theme.Font.body(size: 11.5, wght: 500))
            }
            .foregroundStyle(isActive ? Theme.Color.bg : Theme.Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(isActive ? Theme.Color.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("\(id.displayName) sessions")
    }
}
