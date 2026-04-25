import SwiftUI
import MarkdownUI
import AppKit

/// Modal opened by "Chronicle → Check for updates…". Fires an HTTP request
/// to the GitHub Releases API and either shows release notes + Download
/// button (update available) or a tiny toast-style panel (up to date).
struct UpdateCheckerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: UpdateCheckOutcome? = nil
    @State private var inFlight: Bool = true

    private let checker: UpdateChecker

    init(checker: UpdateChecker = UpdateChecker()) {
        self.checker = checker
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            content
        }
        .frame(width: 540, height: 460)
        .background(Theme.Color.bg)
        .task {
            await runCheck()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CHECK FOR UPDATES")
                    .font(Theme.Font.mono(size: 10.5, wght: 600))
                    .foregroundStyle(Theme.Color.accent)
                    .kerning(1.6)
                Text("Chronicle " + UpdateChecker.currentVersion())
                    .font(Theme.Font.display(size: 16, wght: 600))
                    .foregroundStyle(Theme.Color.text)
            }
            Spacer()
            Button(action: { dismiss() }) {
                Text("Close")
                    .font(Theme.Font.mono(size: 11, wght: 500))
                    .foregroundStyle(Theme.Color.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.Color.bgElev)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Theme.Color.ruleStrong, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.Color.bgElev)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if inFlight {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking GitHub Releases…")
                    .font(Theme.Font.mono(size: 11, wght: 400))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            outcomeView
        }
    }

    @ViewBuilder
    private var outcomeView: some View {
        switch outcome {
        case .upToDate(let cur):
            upToDate(version: cur)

        case .updateAvailable(let release, _):
            updateAvailable(release: release)

        case .error(let msg):
            errorState(msg)

        case .none:
            Color.clear
        }
    }

    private func upToDate(version: String) -> some View {
        VStack(spacing: 12) {
            Text("You're on the latest release")
                .font(Theme.Font.display(size: 18, wght: 600))
                .foregroundStyle(Theme.Color.text)
            Text("Chronicle \(version) · no updates available.")
                .font(Theme.Font.mono(size: 12, wght: 400))
                .foregroundStyle(Theme.Color.textMuted)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't reach GitHub")
                .font(Theme.Font.display(size: 16, wght: 600))
                .foregroundStyle(Theme.Color.text)
            Text(message)
                .font(Theme.Font.mono(size: 11.5, wght: 400))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                Task { await runCheck() }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func updateAvailable(release: GitHubRelease) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NEW RELEASE")
                        .font(Theme.Font.mono(size: 10, wght: 600))
                        .foregroundStyle(Theme.Color.accent)
                        .kerning(1.6)
                    Text(release.name ?? release.tagName)
                        .font(Theme.Font.display(size: 17, wght: 600))
                        .foregroundStyle(Theme.Color.text)
                }
                Spacer()
                Button(action: { openDownload(url: release.downloadURL) }) {
                    Text("Download →")
                        .font(Theme.Font.mono(size: 11.5, wght: 600))
                        .foregroundStyle(Theme.Color.onAccent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.Color.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)

            Rectangle().fill(Theme.Color.rule).frame(height: 1)

            ScrollView {
                Markdown(release.body ?? "_No release notes._")
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func runCheck() async {
        inFlight = true
        outcome = await checker.check()
        inFlight = false
    }

    private func openDownload(url raw: String) {
        guard let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
        dismiss()
    }
}
