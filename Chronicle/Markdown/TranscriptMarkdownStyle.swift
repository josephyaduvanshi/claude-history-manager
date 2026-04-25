import SwiftUI
import MarkdownUI

/// Chronicle's markdown theme for the transcript center column. Designed to
/// match the typography + color system from `transcript.html` (Geist body,
/// Geist Mono code, Bricolage headings, coral accent).
enum TranscriptMarkdownStyle {

    /// Theme used for every rendered user / assistant markdown body. Call
    /// `.markdownTheme(TranscriptMarkdownStyle.theme)` on each `Markdown`.
    static let theme: MarkdownUI.Theme = MarkdownUI.Theme()
        .text {
            ForegroundColor(Theme.Color.text)
            FontSize(14.5)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(13)
            ForegroundColor(Theme.Color.txCodeInlineFg)
            BackgroundColor(Theme.Color.txCodeBgInline)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(Theme.Color.accent)
            UnderlineStyle(.single)
        }
        // MARK: Headings — Bricolage display, sizes 22/18/16
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamily(.custom(Theme.Family.display))
                    FontSize(22)
                    FontWeight(.semibold)
                    ForegroundColor(Theme.Color.text)
                }
                .markdownMargin(top: 18, bottom: 10)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamily(.custom(Theme.Family.display))
                    FontSize(18)
                    FontWeight(.semibold)
                    ForegroundColor(Theme.Color.text)
                }
                .markdownMargin(top: 16, bottom: 10)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamily(.custom(Theme.Family.display))
                    FontSize(16)
                    FontWeight(.semibold)
                    ForegroundColor(Theme.Color.text)
                }
                .markdownMargin(top: 14, bottom: 8)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 12)
        }
        .blockquote { configuration in
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Theme.Color.accent)
                    .frame(width: 2)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(Theme.Color.textMuted)
                    }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
        }
        .list { configuration in
            configuration.label
                .markdownMargin(top: 4, bottom: 12)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 4)
        }
        .codeBlock { configuration in
            SplashCodeBlockView(
                language: configuration.language,
                content: configuration.content
            )
            .markdownMargin(top: 8, bottom: 12)
        }
        .thematicBreak {
            Rectangle()
                .fill(Theme.Color.rule)
                .frame(height: 1)
                .padding(.vertical, 8)
        }
}
