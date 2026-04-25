import SwiftUI
import AppKit
import Splash

/// Bridges Splash syntax highlighting into SwiftUI for ``` fenced code
/// blocks. swift-markdown-ui's theme accepts a custom `codeBlock` view,
/// and this is what we render.
///
/// Splash only ships one built-in grammar. Swift. We detect the info
/// string on the fence (e.g. ```swift, ```bash) and either use Swift
/// highlighting when applicable or fall back to a plain monospaced
/// rendering with Chronicle's dark theme.
struct SplashCodeBlockView: View {
    let language: String?
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = prettyLanguageLabel {
                Text(lang)
                    .font(Theme.Font.mono(size: 10, wght: 500))
                    .foregroundStyle(Theme.Color.textFaint)
                    .kerning(1.0)
                    .textCase(.uppercase)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                attributedCode
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Theme.Color.txCodeBgBlock)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.Color.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Highlighted body

    /// Defensive cap; extremely large fenced blocks (eg. a 5MB grep dump
    /// pasted into the assistant turn) can lock up SwiftUI's text layout
    /// engine. Render the head and append a truncation marker.
    private static let maxRenderableChars = 32 * 1024

    @ViewBuilder
    private var attributedCode: some View {
        if useSwiftHighlighting {
            Text(AttributedString(Self.highlightSwift(safeContent)))
        } else {
            Text(safeContent)
                .font(Theme.Font.mono(size: 12.5, wght: 400))
                .foregroundStyle(Theme.Color.text)
                .monospacedDigit()
        }
    }

    private var safeContent: String {
        if content.count <= Self.maxRenderableChars { return content }
        let head = content.prefix(Self.maxRenderableChars)
        return String(head) + "\n…[truncated \(content.count - Self.maxRenderableChars) chars]"
    }

    private var useSwiftHighlighting: Bool {
        guard let lang = language?.lowercased() else { return false }
        // Splash's built-in SwiftGrammar gives good results only for Swift.
        // Everything else falls back to the plain mono renderer; still
        // readable, and avoids pretending we speak Bash/Python.
        return lang == "swift"
    }

    private var prettyLanguageLabel: String? {
        guard let raw = language?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    // MARK: - Splash -> NSAttributedString

    private static let swiftHighlighter: SyntaxHighlighter<AttributedStringOutputFormat> = {
        let monoFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        let fallbackPath = monoFont.fontName
        let font = Splash.Font(path: fallbackPath, size: 12.5)
        let theme = Splash.Theme(
            font: font,
            plainTextColor: Self.nsColor(Theme.Color.text),
            tokenColors: [
                .keyword:       Self.nsColor(Theme.Color.synKeyword),
                .string:        Self.nsColor(Theme.Color.synString),
                .type:          Self.nsColor(Theme.Color.synType),
                .call:          Self.nsColor(Theme.Color.synType),
                .number:        Self.nsColor(Theme.Color.synNumber),
                .comment:       Self.nsColor(Theme.Color.synComment),
                .property:      Self.nsColor(Theme.Color.textMuted),
                .dotAccess:     Self.nsColor(Theme.Color.textMuted),
                .preprocessing: Self.nsColor(Theme.Color.synNumber),
            ],
            backgroundColor: Self.nsColor(Theme.Color.txCodeBgBlock)
        )
        return SyntaxHighlighter(format: AttributedStringOutputFormat(theme: theme))
    }()

    static func highlightSwift(_ code: String) -> NSAttributedString {
        // Splash's highlighter is a struct with mutating state internally;
        // calling the non-mutating `.highlight` is safe per the library API.
        swiftHighlighter.highlight(code)
    }

    /// Bridges SwiftUI Color → NSColor for Splash's NSColor-based theme.
    /// Uses sRGB since our palette is defined in sRGB terms already.
    private static func nsColor(_ color: SwiftUI.Color) -> NSColor {
        NSColor(color)
    }
}
