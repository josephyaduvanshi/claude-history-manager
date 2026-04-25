import SwiftUI
import Foundation

/// Chronicle's design tokens. Colors are sRGB approximations of the OKLCH
/// values defined in `.superpowers/brainstorm/.../main-window-v2.html` (the
/// authoritative design spec). Font helpers return `Font.custom(...)` targeting
/// the bundled Bricolage Grotesque / Geist / Geist Mono variable fonts, and use
/// the macOS 15+ `.width(_:)` and `.opticalSizing(_:)` modifiers when available
/// to drive the variable axes precisely.
public enum Theme {

    // MARK: - Active theme

    /// The currently active named theme. AppearanceStore writes this when the
    /// user picks a different palette in Settings. All `Theme.Color.*` tokens
    /// resolve through `palette` against this value, so flipping it re-tints
    /// every view that re-renders.
    ///
    /// Marked `nonisolated(unsafe)` because the original `Theme.Color.*`
    /// tokens were `static let`s with no actor isolation; many call sites
    /// (markdown styles, NSColor providers, FormatStyle helpers) read them
    /// off the main actor. Writes happen exclusively from `AppearanceStore`
    /// on the main actor, so the unsafe annotation is sound in practice.
    public nonisolated(unsafe) static var currentTheme: ChronicleTheme = .darkChronicle

    /// Palette resolved for the active theme. Computed each access — cheap, no
    /// caching needed since `Palette` is just a struct of `SwiftUI.Color`s.
    public static var palette: Palette { currentTheme.palette }

    // MARK: - Palette

    /// All themable color tokens for a single named theme. The accent-derived
    /// soft / edge tints are computed from `accent` so a theme only needs to
    /// declare the base hue.
    public struct Palette {
        public let bg: SwiftUI.Color
        public let bgElev: SwiftUI.Color
        public let bgElev2: SwiftUI.Color
        public let bgHover: SwiftUI.Color
        public let bgSelected: SwiftUI.Color

        public let rule: SwiftUI.Color
        public let ruleStrong: SwiftUI.Color

        public let text: SwiftUI.Color
        public let textMuted: SwiftUI.Color
        public let textDim: SwiftUI.Color
        public let textFaint: SwiftUI.Color

        public let accent: SwiftUI.Color
        public let accentSoft: SwiftUI.Color
        public let accentEdge: SwiftUI.Color
        public let onAccent: SwiftUI.Color

        // Tag palettes (bg / fg pairs).
        public let tag1Bg: SwiftUI.Color
        public let tag1Fg: SwiftUI.Color
        public let tag2Bg: SwiftUI.Color
        public let tag2Fg: SwiftUI.Color
        public let tag3Bg: SwiftUI.Color
        public let tag3Fg: SwiftUI.Color

        public let chipBg: SwiftUI.Color

        // Transcript-specific tokens (Plan 05).
        public let txToolBlue: SwiftUI.Color
        public let txToolBg: SwiftUI.Color
        public let txToolBorder: SwiftUI.Color
        public let txToolResultBg: SwiftUI.Color
        public let txCodeInlineFg: SwiftUI.Color
    }

    // MARK: - Colors

    public enum Color {
        // Background tones (darkest -> lightest elevation)
        public static var bg:         SwiftUI.Color { Theme.palette.bg }
        public static var bgElev:     SwiftUI.Color { Theme.palette.bgElev }
        public static var bgElev2:    SwiftUI.Color { Theme.palette.bgElev2 }
        public static var bgHover:    SwiftUI.Color { Theme.palette.bgHover }
        public static var bgSelected: SwiftUI.Color { Theme.palette.bgSelected }

        // Rules / separators
        public static var rule:       SwiftUI.Color { Theme.palette.rule }
        public static var ruleStrong: SwiftUI.Color { Theme.palette.ruleStrong }

        // Text ramp
        public static var text:       SwiftUI.Color { Theme.palette.text }
        public static var textMuted:  SwiftUI.Color { Theme.palette.textMuted }
        public static var textDim:    SwiftUI.Color { Theme.palette.textDim }
        public static var textFaint:  SwiftUI.Color { Theme.palette.textFaint }

        // Accent + state colors.
        public static var accent:     SwiftUI.Color { Theme.palette.accent }
        public static var accentSoft: SwiftUI.Color { Theme.palette.accentSoft }
        public static var accentEdge: SwiftUI.Color { Theme.palette.accentEdge }

        // Stable across themes (semantic state colors don't follow palette).
        public static let live          = SwiftUI.Color(red: 0.400, green: 0.816, blue: 0.431)
        public static let dirty         = SwiftUI.Color(red: 0.898, green: 0.706, blue: 0.333)

        public static var onAccent:   SwiftUI.Color { Theme.palette.onAccent }

        // Traffic-light glyph colors.
        public static let tlRed         = SwiftUI.Color(red: 0.863, green: 0.357, blue: 0.345)
        public static let tlAmber       = SwiftUI.Color(red: 0.949, green: 0.749, blue: 0.388)
        public static let tlGreen       = SwiftUI.Color(red: 0.341, green: 0.757, blue: 0.396)

        // Tag palettes
        public static var tag1Bg: SwiftUI.Color { Theme.palette.tag1Bg }
        public static var tag1Fg: SwiftUI.Color { Theme.palette.tag1Fg }
        public static var tag2Bg: SwiftUI.Color { Theme.palette.tag2Bg }
        public static var tag2Fg: SwiftUI.Color { Theme.palette.tag2Fg }
        public static var tag3Bg: SwiftUI.Color { Theme.palette.tag3Bg }
        public static var tag3Fg: SwiftUI.Color { Theme.palette.tag3Fg }

        public static var chipBg: SwiftUI.Color { Theme.palette.chipBg }

        // MARK: Transcript-specific tokens

        public static var txToolBlue:     SwiftUI.Color { Theme.palette.txToolBlue }
        public static var txToolBg:       SwiftUI.Color { Theme.palette.txToolBg }
        public static var txToolBorder:   SwiftUI.Color { Theme.palette.txToolBorder }
        public static var txToolResultBg: SwiftUI.Color { Theme.palette.txToolResultBg }

        /// Inline-code background inside rendered markdown turns. Matches bgElev.
        public static var txCodeBgInline: SwiftUI.Color { Theme.palette.bgElev }

        /// Block-code background for ``` fenced blocks.
        public static var txCodeBgBlock: SwiftUI.Color { Theme.palette.bgElev }

        public static var txCodeInlineFg: SwiftUI.Color { Theme.palette.txCodeInlineFg }

        /// Role-label color for the "YOU" mono small-caps.
        public static var txRoleYou: SwiftUI.Color { Theme.palette.textFaint }
        /// Role-label color for the "CLAUDE" mono small-caps.
        public static var txRoleClaude: SwiftUI.Color { Theme.palette.accent }

        /// Number slot color (the big `01`, `02`, ...).
        public static var txNumber: SwiftUI.Color { Theme.palette.textFaint }
        /// Number slot color for assistant turns; coral with reduced opacity.
        public static var txNumberAssistant: SwiftUI.Color { Theme.palette.accent.opacity(0.6) }

        // Splash syntax colors; shared between Splash and any manual
        // inline highlight for code. Tuned to read well on `txCodeBgBlock`.
        public static let synKeyword       = SwiftUI.Color(red: 0.78, green: 0.55, blue: 0.92)
        public static let synString        = SwiftUI.Color(red: 0.63, green: 0.82, blue: 0.53)
        public static let synComment       = SwiftUI.Color(red: 0.44, green: 0.43, blue: 0.41)
        public static let synType          = SwiftUI.Color(red: 0.52, green: 0.79, blue: 0.86)
        public static let synNumber        = SwiftUI.Color(red: 0.91, green: 0.69, blue: 0.36)

        /// Maps a `Workspace.group` to a dot color for sidebar rows.
        /// Falls back to textMuted for unknown groups.
        public static func dotColor(forGroup group: String) -> SwiftUI.Color {
            switch group.lowercased() {
            case "flutter":        return oklchColor(l: 0.70, c: 0.12, h: 250)
            case "security":       return oklchColor(l: 0.72, c: 0.14, h: 145)
            case "ai", "ai/claude",
                 "claude":         return oklchColor(l: 0.70, c: 0.15, h: 300)
            case "work":           return oklchColor(l: 0.75, c: 0.13,  h:  75)
            case "rust":           return oklchColor(l: 0.70, c: 0.11,  h: 200)
            case "go":             return oklchColor(l: 0.68, c: 0.16,  h:  30)
            case "python":         return oklchColor(l: 0.70, c: 0.11,  h: 180)
            case "web":            return oklchColor(l: 0.72, c: 0.15,  h: 100)
            default:               return textMuted
            }
        }

        /// Dot color for a `WorkspaceCategory`.
        public static func dotColor(forCategory category: WorkspaceCategory) -> SwiftUI.Color {
            switch category {
            case .flutter:  return oklchColor(l: 0.70, c: 0.12, h: 250)
            case .security: return oklchColor(l: 0.72, c: 0.14, h: 145)
            case .aiClaude: return oklchColor(l: 0.70, c: 0.15, h: 300)
            case .work:     return oklchColor(l: 0.75, c: 0.13, h:  75)
            case .rust:     return oklchColor(l: 0.70, c: 0.11, h:  35)
            case .go:       return oklchColor(l: 0.68, c: 0.16, h: 220)
            case .python:   return oklchColor(l: 0.70, c: 0.11, h: 180)
            case .web:      return oklchColor(l: 0.72, c: 0.15, h: 100)
            case .other:    return textDim
            }
        }

        /// Convert OKLCH (L [0,1], C [0,~0.4], h [0,360°]) to an sRGB
        /// SwiftUI.Color. Uses Björn Ottosson's reference matrix + standard
        /// sRGB gamma companding.
        static func oklchColor(l: Double, c: Double, h: Double) -> SwiftUI.Color {
            let hRad = h * .pi / 180.0
            let a = c * cos(hRad)
            let b = c * sin(hRad)

            let lp = l + 0.3963377774 * a + 0.2158037573 * b
            let mp = l - 0.1055613458 * a - 0.0638541728 * b
            let sp = l - 0.0894841775 * a - 1.2914855480 * b

            let lc = lp * lp * lp
            let mc = mp * mp * mp
            let sc = sp * sp * sp

            let rLin =  4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
            let gLin = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
            let bLin = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

            return SwiftUI.Color(
                red: srgbGamma(rLin),
                green: srgbGamma(gLin),
                blue: srgbGamma(bLin)
            )
        }

        private static func srgbGamma(_ v: Double) -> Double {
            let clamped = max(0.0, min(1.0, v))
            if clamped > 0.0031308 {
                return 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
            } else {
                return 12.92 * clamped
            }
        }
    }

    // MARK: - Fonts

    /// Font family names resolved from the bundled TTFs via `FontLoader`.
    public enum Family {
        public static let display = "Bricolage Grotesque"
        public static let body    = "Geist"
        public static let mono    = "Geist Mono"
    }

    public enum Font {
        // MARK: Base builders

        public static func display(size: CGFloat,
                                   wdth: CGFloat = 100,
                                   wght: CGFloat = 500,
                                   opsz: CGFloat? = nil) -> SwiftUI.Font {
            _ = opsz
            let base = SwiftUI.Font.custom(Family.display, size: size)
            if #available(macOS 15, *) {
                return base
                    .width(SwiftUI.Font.Width(wdth / 100.0))
                    .weight(weight(from: wght))
            } else {
                return base.weight(weight(from: wght))
            }
        }

        public static func body(size: CGFloat, wght: CGFloat = 400) -> SwiftUI.Font {
            SwiftUI.Font.custom(Family.body, size: size).weight(weight(from: wght))
        }

        public static func mono(size: CGFloat, wght: CGFloat = 400) -> SwiftUI.Font {
            SwiftUI.Font.custom(Family.mono, size: size).weight(weight(from: wght))
        }

        private static func weight(from value: CGFloat) -> SwiftUI.Font.Weight {
            switch value {
            case ..<350:  return .ultraLight
            case ..<400:  return .light
            case ..<450:  return .regular
            case ..<550:  return .medium
            case ..<650:  return .semibold
            case ..<750:  return .bold
            case ..<850:  return .heavy
            default:      return .black
            }
        }

        // MARK: Title bar
        public static let tlTitle      = display(size: 13, wdth: 95, wght: 500, opsz: 24)
        public static let tlTitleBold  = display(size: 13, wdth: 95, wght: 600, opsz: 24)
        public static let tlMeta       = mono(size: 11, wght: 400)

        // MARK: Global search bar
        public static let searchGlyph  = display(size: 16, wdth: 95, wght: 600, opsz: 24)
        public static let searchInput  = body(size: 14.5, wght: 400)
        public static let searchHint   = mono(size: 11, wght: 400)
        public static let searchHintB  = mono(size: 11, wght: 500)
        public static let searchKbd    = mono(size: 10.5, wght: 400)
        public static let searchPill   = body(size: 12, wght: 500)

        // MARK: Sidebar
        public static let sbLabel      = display(size: 10, wdth: 110, wght: 600, opsz: 12)
        public static let sbRow        = body(size: 12.5, wght: 400)
        public static let sbRowActive  = body(size: 12.5, wght: 500)
        public static let sbNum        = mono(size: 10, wght: 400)
        public static let sbLabelCount = mono(size: 9, wght: 400)

        // MARK: Session list
        public static let listTitle    = display(size: 22, wdth: 100, wght: 600, opsz: 32)
        public static let listMeta     = mono(size: 11, wght: 400)
        public static let listFilter   = mono(size: 11, wght: 400)
        public static let listFilterIn = body(size: 11.5, wght: 400)
        public static let listSort     = body(size: 11.5, wght: 400)
        public static let sessionTitle = body(size: 14.5, wght: 500)
        public static let sessionWhen  = mono(size: 10.5, wght: 400)
        public static let sessionMeta  = mono(size: 10.5, wght: 400)
        public static let tag          = body(size: 10.5, wght: 500)

        // MARK: Preview
        public static let pvEyebrow       = mono(size: 10.5, wght: 500)
        public static let pvTitle         = display(size: 26, wdth: 100, wght: 600, opsz: 36)
        public static let pvStatLabel     = mono(size: 9.5, wght: 500)
        public static let pvStatValue     = display(size: 18, wdth: 100, wght: 500, opsz: 24)
        public static let pvStatValueMono = mono(size: 15, wght: 500)
        public static let pvStatSub       = mono(size: 10, wght: 400)
        public static let pvSectionTitle  = display(size: 11, wdth: 110, wght: 600, opsz: 14)
        public static let pvMore          = mono(size: 10, wght: 400)
        public static let msgRole         = mono(size: 10, wght: 500)
        public static let msgContent      = body(size: 13, wght: 400)
        public static let msgContentCode  = mono(size: 12, wght: 400)

        // MARK: Action bar
        public static let btn             = body(size: 12.5, wght: 500)
        public static let btnPrimary      = body(size: 12.5, wght: 600)
        public static let btnKbd          = mono(size: 10, wght: 400)
        public static let terminalPick    = mono(size: 11, wght: 400)
        public static let terminalPickB   = body(size: 12, wght: 500)

        // MARK: Transcript view (Plan 05)
        public static let txNumber        = display(size: 22, wdth: 110, wght: 700, opsz: 32)
        public static let txRole          = mono(size: 10.5, wght: 500)
        public static let txTime          = mono(size: 10, wght: 400)
        public static let txHero          = display(size: 32, wdth: 100, wght: 600, opsz: 96)
        public static let txByline        = mono(size: 11.5, wght: 400)
        public static let txEyebrow       = mono(size: 10.5, wght: 500)
        public static let txBody          = body(size: 14.5, wght: 400)
        public static let txMono          = mono(size: 13, wght: 400)
        public static let txToolHead      = mono(size: 12, wght: 400)
        public static let txToolBody      = mono(size: 12, wght: 400)
        public static let txTocItem       = body(size: 12, wght: 500)
        public static let txTocNum        = mono(size: 10.5, wght: 400)
        public static let txTocRole       = mono(size: 9, wght: 500)
        public static let txMetaLabel     = display(size: 10, wdth: 110, wght: 600, opsz: 12)
        public static let txMetaValText   = body(size: 12.5, wght: 500)
        public static let txMetaValMono   = mono(size: 12, wght: 500)
        public static let txMetaKey       = body(size: 12, wght: 400)
        public static let txMetaFile      = mono(size: 11, wght: 400)
        public static let txMetaFileCount = mono(size: 10.5, wght: 500)

        // MARK: Legacy aliases
        public static let bodyBase      = body(size: 13, wght: 400)
        public static let bodyMedium    = body(size: 13, wght: 500)
        public static let titleSmall    = body(size: 14.5, wght: 500)
        public static let titleLarge    = display(size: 22, wdth: 100, wght: 600, opsz: 32)
        public static let titleHero     = display(size: 26, wdth: 100, wght: 600, opsz: 36)
        public static let label         = display(size: 10, wdth: 110, wght: 600, opsz: 12)
        public static let mono: SwiftUI.Font = mono(size: 11, wght: 400)
        public static let monoSmall: SwiftUI.Font = mono(size: 10, wght: 400)
    }

    // MARK: - Spacing (convenience tokens)

    public enum Space {
        public static let xs:  CGFloat = 4
        public static let sm:  CGFloat = 8
        public static let md:  CGFloat = 14
        public static let lg:  CGFloat = 18
        public static let xl:  CGFloat = 24
    }
}

// MARK: - Named themes

/// Named, opinionated palettes the user picks from in Settings → Appearance.
/// Each theme owns both its color values and its preferred `ColorScheme`
/// (controls macOS materials, system controls, and traffic lights).
public enum ChronicleTheme: String, CaseIterable, Identifiable, Sendable {
    case darkChronicle
    case github
    case gothic
    case newsprint
    case night
    case pixyll
    case whitey

    public var id: String { rawValue }

    /// Display order for the Settings picker. Dark Chronicle is the default
    /// and shown first; the rest are alphabetical.
    public static let displayOrder: [ChronicleTheme] = [
        .darkChronicle, .github, .gothic, .newsprint, .night, .pixyll, .whitey,
    ]

    public var displayName: String {
        switch self {
        case .darkChronicle: return "Dark Chronicle"
        case .github:        return "GitHub"
        case .gothic:        return "Gothic"
        case .newsprint:     return "Newsprint"
        case .night:         return "Night"
        case .pixyll:        return "Pixyll"
        case .whitey:        return "Whitey"
        }
    }

    /// macOS appearance the theme is designed for. Passed to
    /// `.preferredColorScheme(_:)` so window chrome / system controls match
    /// the palette's intent regardless of the user's OS-level setting.
    public var defaultColorScheme: SwiftUI.ColorScheme {
        switch self {
        case .darkChronicle, .gothic, .night: return .dark
        case .github, .newsprint, .pixyll, .whitey: return .light
        }
    }

    /// Resolved color palette. The Dark Chronicle palette intentionally
    /// matches the original `Theme.swift` dark values byte-for-byte so users
    /// who never open Settings see no regression.
    public var palette: Theme.Palette {
        switch self {
        case .darkChronicle: return .darkChronicle
        case .github:        return .github
        case .gothic:        return .gothic
        case .newsprint:     return .newsprint
        case .night:         return .night
        case .pixyll:        return .pixyll
        case .whitey:        return .whitey
        }
    }
}

// MARK: - Palette definitions

public extension Theme.Palette {

    /// Helper: opaque sRGB color from a packed `0xRRGGBB` triple.
    private static func rgb(_ hex: UInt32) -> SwiftUI.Color {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        return SwiftUI.Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }

    // The original dark palette, preserved exactly as it shipped before the
    // named-theme refactor. Hex values come from the dark branch of the old
    // `Color(light:dark:)` initializers.
    static let darkChronicle = Theme.Palette(
        bg:             rgb(0x12120F),
        bgElev:         rgb(0x181613),
        bgElev2:        rgb(0x1E1C1A),
        bgHover:        rgb(0x1F1C1A),
        bgSelected:     rgb(0x29221F),
        rule:           rgb(0x21201F),
        ruleStrong:     rgb(0x2E2C28),
        text:           rgb(0xF4F3F1),
        textMuted:      rgb(0xA09C95),
        textDim:        rgb(0x6D6964),
        textFaint:      rgb(0x494643),
        accent:         SwiftUI.Color(red: 0.957, green: 0.525, blue: 0.400),
        accentSoft:     SwiftUI.Color(red: 0.957, green: 0.525, blue: 0.400).opacity(0.12),
        accentEdge:     SwiftUI.Color(red: 0.957, green: 0.525, blue: 0.400).opacity(0.40),
        onAccent:       rgb(0xFFFFFF),
        tag1Bg:         rgb(0x1C2848),
        tag1Fg:         rgb(0x8CB2EE),
        tag2Bg:         rgb(0x1A303B),
        tag2Fg:         rgb(0x8CCCDE),
        tag3Bg:         rgb(0x361C40),
        tag3Fg:         rgb(0xEAA3FA),
        chipBg:         rgb(0x1C1A18),
        txToolBlue:     rgb(0x7FA2EA),
        txToolBg:       rgb(0x191B21),
        txToolBorder:   rgb(0x242A3B),
        txToolResultBg: rgb(0x15151A),
        txCodeInlineFg: rgb(0xDAD4CC)
    )

    // GitHub Light: clean white background, blue accent, subtle gray rules.
    static let github = Theme.Palette(
        bg:             rgb(0xFFFFFF),
        bgElev:         rgb(0xF6F8FA),
        bgElev2:        rgb(0xEAEEF2),
        bgHover:        rgb(0xF3F4F6),
        bgSelected:     rgb(0xDDF4FF),
        rule:           rgb(0xD0D7DE),
        ruleStrong:     rgb(0xB1BAC4),
        text:           rgb(0x1F2328),
        textMuted:      rgb(0x57606A),
        textDim:        rgb(0x6E7781),
        textFaint:      rgb(0x8C959F),
        accent:         rgb(0x0969DA),
        accentSoft:     rgb(0x0969DA).opacity(0.10),
        accentEdge:     rgb(0x0969DA).opacity(0.45),
        onAccent:       rgb(0xFFFFFF),
        tag1Bg:         rgb(0xDDF4FF),
        tag1Fg:         rgb(0x0969DA),
        tag2Bg:         rgb(0xDAFBE1),
        tag2Fg:         rgb(0x1A7F37),
        tag3Bg:         rgb(0xFFF1E5),
        tag3Fg:         rgb(0x9A6700),
        chipBg:         rgb(0xEAEEF2),
        txToolBlue:     rgb(0x0969DA),
        txToolBg:       rgb(0xDDF4FF),
        txToolBorder:   rgb(0xB6E3FF),
        txToolResultBg: rgb(0xF6F8FA),
        txCodeInlineFg: rgb(0x24292F)
    )

    // Gothic: deep purple/black with blood-red highlights.
    static let gothic = Theme.Palette(
        bg:             rgb(0x0A0613),
        bgElev:         rgb(0x110A1F),
        bgElev2:        rgb(0x180E2B),
        bgHover:        rgb(0x1F1234),
        bgSelected:     rgb(0x2A1A48),
        rule:           rgb(0x261A3A),
        ruleStrong:     rgb(0x3B2755),
        text:           rgb(0xE5DEFF),
        textMuted:      rgb(0xA59BC9),
        textDim:        rgb(0x7B6FA0),
        textFaint:      rgb(0x564B7A),
        accent:         rgb(0xB084FF),
        accentSoft:     rgb(0xB084FF).opacity(0.14),
        accentEdge:     rgb(0xB084FF).opacity(0.45),
        onAccent:       rgb(0x0A0613),
        tag1Bg:         rgb(0x2A1A48),
        tag1Fg:         rgb(0xB084FF),
        tag2Bg:         rgb(0x3F0F1F),
        tag2Fg:         rgb(0xE05A6E),
        tag3Bg:         rgb(0x1A2B3F),
        tag3Fg:         rgb(0x88AEDD),
        chipBg:         rgb(0x180E2B),
        txToolBlue:     rgb(0x88AEDD),
        txToolBg:       rgb(0x14182A),
        txToolBorder:   rgb(0x232846),
        txToolResultBg: rgb(0x0E0A1A),
        txCodeInlineFg: rgb(0xD9CFFB)
    )

    // Newsprint: cream/sepia, warm brown accent.
    static let newsprint = Theme.Palette(
        bg:             rgb(0xF5F1E8),
        bgElev:         rgb(0xFBF8F0),
        bgElev2:        rgb(0xEEE7D5),
        bgHover:        rgb(0xE8DFC7),
        bgSelected:     rgb(0xE3D3A8),
        rule:           rgb(0xD8CBA8),
        ruleStrong:     rgb(0xBFAE82),
        text:           rgb(0x2A1F14),
        textMuted:      rgb(0x5C4A33),
        textDim:        rgb(0x7B6645),
        textFaint:      rgb(0xA08F6E),
        accent:         rgb(0x8B5A2B),
        accentSoft:     rgb(0x8B5A2B).opacity(0.12),
        accentEdge:     rgb(0x8B5A2B).opacity(0.45),
        onAccent:       rgb(0xFBF8F0),
        tag1Bg:         rgb(0xE3D9C0),
        tag1Fg:         rgb(0x6B4F2A),
        tag2Bg:         rgb(0xDDE3CB),
        tag2Fg:         rgb(0x4F6B2A),
        tag3Bg:         rgb(0xE8D3D0),
        tag3Fg:         rgb(0x8B3B2B),
        chipBg:         rgb(0xEEE7D5),
        txToolBlue:     rgb(0x355C8A),
        txToolBg:       rgb(0xE5E8F0),
        txToolBorder:   rgb(0xC3CADD),
        txToolResultBg: rgb(0xEEE7D5),
        txCodeInlineFg: rgb(0x3D2E1E)
    )

    // Night: true midnight blue, no warmth.
    static let night = Theme.Palette(
        bg:             rgb(0x0F1424),
        bgElev:         rgb(0x141A2E),
        bgElev2:        rgb(0x1B2238),
        bgHover:        rgb(0x1F2740),
        bgSelected:     rgb(0x263158),
        rule:           rgb(0x232C46),
        ruleStrong:     rgb(0x33406A),
        text:           rgb(0xC8D3F5),
        textMuted:      rgb(0x8C99C2),
        textDim:        rgb(0x6371A0),
        textFaint:      rgb(0x434F77),
        accent:         rgb(0x6EA1FF),
        accentSoft:     rgb(0x6EA1FF).opacity(0.13),
        accentEdge:     rgb(0x6EA1FF).opacity(0.45),
        onAccent:       rgb(0x0F1424),
        tag1Bg:         rgb(0x1F2D52),
        tag1Fg:         rgb(0x6EA1FF),
        tag2Bg:         rgb(0x172E3F),
        tag2Fg:         rgb(0x6FC8E0),
        tag3Bg:         rgb(0x2B1F44),
        tag3Fg:         rgb(0xB69CFF),
        chipBg:         rgb(0x1B2238),
        txToolBlue:     rgb(0x6EA1FF),
        txToolBg:       rgb(0x16203A),
        txToolBorder:   rgb(0x263158),
        txToolResultBg: rgb(0x121829),
        txCodeInlineFg: rgb(0xC8D3F5)
    )

    // Pixyll: crisp Tufte/Pixyll, red accent, sharp narrow rules.
    static let pixyll = Theme.Palette(
        bg:             rgb(0xFFFFFF),
        bgElev:         rgb(0xFAFAFA),
        bgElev2:        rgb(0xF1F1F1),
        bgHover:        rgb(0xEEEEEE),
        bgSelected:     rgb(0xFADBD8),
        rule:           rgb(0xE0E0E0),
        ruleStrong:     rgb(0xBDBDBD),
        text:           rgb(0x313131),
        textMuted:      rgb(0x595959),
        textDim:        rgb(0x7A7A7A),
        textFaint:      rgb(0xA8A8A8),
        accent:         rgb(0xC0392B),
        accentSoft:     rgb(0xC0392B).opacity(0.10),
        accentEdge:     rgb(0xC0392B).opacity(0.45),
        onAccent:       rgb(0xFFFFFF),
        tag1Bg:         rgb(0xF1F1F1),
        tag1Fg:         rgb(0x313131),
        tag2Bg:         rgb(0xFADBD8),
        tag2Fg:         rgb(0xC0392B),
        tag3Bg:         rgb(0xE5E5E5),
        tag3Fg:         rgb(0x4A4A4A),
        chipBg:         rgb(0xF1F1F1),
        txToolBlue:     rgb(0x2C3E8C),
        txToolBg:       rgb(0xEEF1FB),
        txToolBorder:   rgb(0xC9D2EC),
        txToolResultBg: rgb(0xF1F1F1),
        txCodeInlineFg: rgb(0x313131)
    )

    // Whitey: pure minimal, near-monochrome, accent stays coral.
    static let whitey = Theme.Palette(
        bg:             rgb(0xFBFBFB),
        bgElev:         rgb(0xFFFFFF),
        bgElev2:        rgb(0xF4F4F4),
        bgHover:        rgb(0xEEEEEE),
        bgSelected:     rgb(0xFCEDE6),
        rule:           rgb(0xE5E5E5),
        ruleStrong:     rgb(0xCFCFCF),
        text:           rgb(0x1A1A1A),
        textMuted:      rgb(0x4F4F4F),
        textDim:        rgb(0x767676),
        textFaint:      rgb(0xA6A6A6),
        accent:         SwiftUI.Color(red: 0.957, green: 0.525, blue: 0.400),
        accentSoft:     SwiftUI.Color(red: 0.957, green: 0.525, blue: 0.400).opacity(0.10),
        accentEdge:     SwiftUI.Color(red: 0.957, green: 0.525, blue: 0.400).opacity(0.45),
        onAccent:       rgb(0xFFFFFF),
        tag1Bg:         rgb(0xEEEEEE),
        tag1Fg:         rgb(0x333333),
        tag2Bg:         rgb(0xE5E5E5),
        tag2Fg:         rgb(0x404040),
        tag3Bg:         rgb(0xFCEDE6),
        tag3Fg:         rgb(0xC75A36),
        chipBg:         rgb(0xF4F4F4),
        txToolBlue:     rgb(0x2F5BC9),
        txToolBg:       rgb(0xEEF2FB),
        txToolBorder:   rgb(0xCFD8EC),
        txToolResultBg: rgb(0xE3E9F5),
        txCodeInlineFg: rgb(0x1A1A1A)
    )
}
