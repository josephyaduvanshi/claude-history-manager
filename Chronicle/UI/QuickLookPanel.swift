import SwiftUI

/// In-app "Quick Peek" panel; a lightweight stand-in for a real Finder
/// Quick Look extension. Shows the session title, stats eyebrow, and the
/// first 40 lines of the transcript in a monospace column.
///
/// Opened via ⌘Y or the title-bar "⤤ Quick Look" button. Deliberately
/// minimal: it's an overlay, not a Finder Quick Look provider. That real
/// handler needs an Xcode-based .appex and is called out in HANDOFF.md.
struct QuickLookPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.transcriptRepository) private var transcriptRepo

    let session: SessionMetadata
    @State private var preview: String = "Loading preview…"
    @State private var onJumpToFull: (() -> Void)?

    init(session: SessionMetadata, onJumpToFull: (() -> Void)? = nil) {
        self.session = session
        self._onJumpToFull = State(initialValue: onJumpToFull)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            body40
            Rectangle().fill(Theme.Color.rule).frame(height: 1)
            footer
        }
        .frame(width: 300, height: 480)
        .background(Theme.Color.bg)
        .task(id: session.sessionID) {
            await loadPreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("QUICK PEEK")
                .font(Theme.Font.mono(size: 10, wght: 600))
                .foregroundStyle(Theme.Color.accent)
                .kerning(1.6)
            Text(session.title)
                .font(Theme.Font.display(size: 15, wght: 600))
                .foregroundStyle(Theme.Color.text)
                .lineLimit(2)
                .truncationMode(.tail)
            Text(metaLine)
                .font(Theme.Font.mono(size: 10.5, wght: 400))
                .foregroundStyle(Theme.Color.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var body40: some View {
        ScrollView {
            Text(preview)
                .font(Theme.Font.mono(size: 11, wght: 400))
                .foregroundStyle(Theme.Color.textMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bgElev)
    }

    private var footer: some View {
        HStack(spacing: 10) {
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

            Spacer()

            Button(action: { onJumpToFull?(); dismiss() }) {
                Text("Open full transcript →")
                    .font(Theme.Font.mono(size: 11, wght: 600))
                    .foregroundStyle(Theme.Color.onAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.Color.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var metaLine: String {
        let words = NumberFormatter()
        words.numberStyle = .decimal
        let tokStr = words.string(from: NSNumber(value: session.tokenCount)) ?? "\(session.tokenCount)"
        return "\(session.messageCount) msgs · \(tokStr) tokens · \(RelativeTime.shortAgo(from: session.lastModifiedAt))"
    }

    private func loadPreview() async {
        guard let repo = transcriptRepo else {
            preview = "Transcript repository not configured."
            return
        }
        do {
            let transcript = try await repo.transcript(
                forSessionID: session.sessionID,
                workspaceID: session.workspaceID
            )
            preview = Self.renderPreview(transcript: transcript, maxLines: 40)
        } catch {
            preview = "Couldn't load transcript: \(error.localizedDescription)"
        }
    }

    /// Pure function: flatten the first `maxLines` lines of a Transcript
    /// into a simple text preview (role prefix + inline text). Exported as
    /// `static` so tests can exercise the truncation logic without SwiftUI.
    static func renderPreview(transcript: Transcript, maxLines: Int) -> String {
        var lines: [String] = []
        outer: for msg in transcript.messages {
            switch msg {
            case .user(let u):
                lines.append("YOU:")
                for line in u.markdown.split(whereSeparator: \.isNewline) {
                    lines.append(String(line))
                    if lines.count >= maxLines { break outer }
                }
                lines.append("")
            case .assistant(let a):
                lines.append("CLAUDE:")
                for line in a.markdown.split(whereSeparator: \.isNewline) {
                    lines.append(String(line))
                    if lines.count >= maxLines { break outer }
                }
                lines.append("")
            case .toolCall(let c):
                lines.append("[tool: \(c.name)] \(c.inlineSummary)")
            }
            if lines.count >= maxLines { break }
        }
        if lines.count > maxLines {
            lines = Array(lines.prefix(maxLines))
            lines.append("…")
        }
        return lines.joined(separator: "\n")
    }
}
