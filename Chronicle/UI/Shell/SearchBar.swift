import SwiftUI

// MARK: - Global search bar

struct SearchBar: View {
    @Environment(AppState.self) private var state
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            inputWrap
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(Theme.Color.bg)
    }

    private var inputWrap: some View {
        @Bindable var s = state
        return HStack(spacing: 12) {
            Text("⊳")
                .font(Theme.Font.searchGlyph)
                .foregroundStyle(Theme.Color.accent)
                .kerning(-0.64) // -0.04em at 16pt

            TextField("", text: $s.searchQuery, prompt:
                Text("Search every session, project, file…")
                    .foregroundStyle(Theme.Color.textFaint)
            )
            .textFieldStyle(.plain)
            .font(Theme.Font.searchInput)
            .foregroundStyle(Theme.Color.text)
            .kerning(-0.0725) // -0.005em at 14.5pt
            .focused($searchFocused)

            HStack(spacing: 2) {
                hintChip("/full:")
                Text("transcript")
                    .font(Theme.Font.searchHint)
                    .foregroundStyle(Theme.Color.textFaint)
                Text("  ").font(Theme.Font.searchHint)
                hintChip("/today")
                Text("  ").font(Theme.Font.searchHint)
                hintChip("/tag:")
                Text("  ").font(Theme.Font.searchHint)
                hintChip("/in:")
            }

            Text("⌘K")
                .font(Theme.Font.searchKbd)
                .foregroundStyle(Theme.Color.textFaint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                )
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .frame(height: 40)
        .background(searchFocused ? Theme.Color.bgElev2 : Theme.Color.bgElev)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(searchFocused ? Theme.Color.accentEdge : Theme.Color.ruleStrong,
                        lineWidth: 1)
        )
        // 3pt accent halo when focused (mockup calls it a "focus ring").
        .background(
            RoundedRectangle(cornerRadius: 11)
                .stroke(searchFocused ? Theme.Color.accentSoft : Color.clear,
                        lineWidth: 3)
                .padding(-3)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    private func hintChip(_ label: String) -> some View {
        Text(label)
            .font(Theme.Font.searchHintB)
            .foregroundStyle(Theme.Color.textDim)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.Color.chipBg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var controls: some View {
        @Bindable var s = state
        return HStack(spacing: 8) {
            // All workspaces pill; active toggles scope between "every workspace"
            // (implicit no filter) and "just the selected workspace".
            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    state.showAllWorkspaces.toggle()
                }
            } label: {
                if state.showAllWorkspaces {
                    activePillLabel("All workspaces", showClose: true)
                } else {
                    inactivePillLabel("This workspace only")
                }
            }
            .buttonStyle(PillScaleStyle())
            .help(state.showAllWorkspaces
                  ? "Restrict search to the selected workspace"
                  : "Search across every workspace")

            Button {
                withAnimation(.easeOut(duration: 0.12)) {
                    state.activeTimeWindow = (state.activeTimeWindow == .last30Days) ? nil : .last30Days
                }
            } label: {
                if state.activeTimeWindow == .last30Days {
                    activePillLabel("Last 30 days", showClose: true)
                } else {
                    inactivePillLabel("Last 30 days")
                }
            }
            .buttonStyle(PillScaleStyle())
            .help("Limit search results to the last 30 days")

            filterMenu
        }
    }

    @State private var filterMenuOpen = false
    private var filterMenu: some View {
        Button {
            filterMenuOpen = true
        } label: {
            inactivePillLabel("+ Filter")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $filterMenuOpen) {
            VStack(alignment: .leading, spacing: 8) {
                Text("More filters")
                    .font(Theme.Font.searchPill)
                    .foregroundStyle(Theme.Color.text)
                Text("Coming in Plan 06 (tags, files, models).")
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .padding(14)
            .frame(minWidth: 260)
            .background(Theme.Color.bgElev)
        }
    }

    private func inactivePillLabel(_ label: String) -> some View {
        Text(label)
            .font(Theme.Font.searchPill)
            .foregroundStyle(Theme.Color.textMuted)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Theme.Color.bgElev)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Button style that scales the label down to ~0.96 on press and back
    /// to 1 on release, with a tiny easeOut. Used on the search pills so
    /// clicks feel registered.
    fileprivate struct PillScaleStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }

    private func activePillLabel(_ label: String, showClose: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.Font.searchPill)
                .foregroundStyle(Theme.Color.accent)
            if showClose {
                Text("×")
                    .font(Theme.Font.mono)
                    .foregroundStyle(Theme.Color.accent.opacity(0.6))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Theme.Color.accentSoft)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.Color.accentEdge, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
