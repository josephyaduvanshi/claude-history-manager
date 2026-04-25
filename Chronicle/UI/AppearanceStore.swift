import SwiftUI
import Combine

/// Holds user personalization preferences (theme, accent, density) and
/// publishes them so `@EnvironmentObject` consumers can react to changes
/// instantly. Persists to `UserDefaults` under stable keys so settings
/// survive across launches.
///
/// Important: this store **does not** mutate `Theme.Color.accent` directly.
/// Views that want to honor a user accent override must read `accentOverride`
/// from the store (via `@EnvironmentObject`) and fall back to
/// `Theme.Color.accent` when it's nil. That keeps the Plan 01.5 visual
/// defaults untouched for users who never open Settings.
@MainActor
public final class AppearanceStore: ObservableObject {
    public static let shared = AppearanceStore()

    // MARK: Keys

    public enum Key {
        public static let theme       = "chronicle.theme"
        public static let themeName   = "chronicle.themeName"
        public static let accent      = "chronicle.accentColor"
        public static let density     = "chronicle.density"
    }

    // MARK: - Theme

    public enum ThemeMode: String, CaseIterable, Identifiable, Sendable {
        case auto, light, dark
        public var id: String { rawValue }

        public var colorScheme: ColorScheme? {
            switch self {
            case .auto:  return nil
            case .light: return .light
            case .dark:  return .dark
            }
        }

        public var label: String {
            switch self {
            case .auto:  return "Auto"
            case .light: return "Light"
            case .dark:  return "Dark"
            }
        }
    }

    @Published public var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Key.theme) }
    }

    // MARK: - Named Theme

    /// The active named palette. Drives every `Theme.Color.*` token plus the
    /// window's `.preferredColorScheme(...)`. Defaults to `.darkChronicle`,
    /// which matches the original Theme.swift dark palette pixel-for-pixel
    /// so users who never open Settings see no visual change.
    @Published public var theme: ChronicleTheme {
        didSet {
            defaults.set(theme.rawValue, forKey: Key.themeName)
            Theme.currentTheme = theme
        }
    }

    // MARK: - Accent

    /// Nil means "use the coral Plan 01.5 default". A stored hex string means
    /// the user picked a custom accent; we render that via `accent` below.
    @Published public var accentHex: String? {
        didSet {
            if let hex = accentHex {
                self.defaults.set(hex, forKey: Key.accent)
            } else {
                self.defaults.removeObject(forKey: Key.accent)
            }
        }
    }

    /// The accent color to render. The user-configured `accentHex` override
    /// only applies to themes whose default accent is coral (Dark Chronicle
    /// and Whitey); other themes always render their bespoke accent so the
    /// palette stays internally coherent.
    public var accent: Color {
        if theme == .darkChronicle || theme == .whitey {
            return accentOverride ?? Theme.Color.accent
        }
        return Theme.Color.accent
    }

    /// The override color, or nil when the default applies.
    public var accentOverride: Color? {
        guard let hex = accentHex, let rgb = Self.decodeHex(hex) else { return nil }
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }

    // MARK: - Density

    public enum Density: String, CaseIterable, Identifiable, Sendable {
        case compact, comfortable, spacious
        public var id: String { rawValue }

        /// Multiplier applied to paddings / row heights. 1.0 is the shipped
        /// default (`.comfortable`).
        public var paddingScale: Double {
            switch self {
            case .compact:     return 0.8
            case .comfortable: return 1.0
            case .spacious:    return 1.2
            }
        }

        public var label: String {
            switch self {
            case .compact:     return "Compact"
            case .comfortable: return "Comfortable"
            case .spacious:    return "Spacious"
            }
        }
    }

    @Published public var density: Density {
        didSet { self.defaults.set(density.rawValue, forKey: Key.density) }
    }

    // MARK: - Init

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let t = defaults.string(forKey: Key.theme).flatMap(ThemeMode.init(rawValue:)) ?? .auto
        self.themeMode = t
        let named = defaults.string(forKey: Key.themeName)
            .flatMap(ChronicleTheme.init(rawValue:)) ?? .darkChronicle
        self.theme = named
        let d = defaults.string(forKey: Key.density).flatMap(Density.init(rawValue:)) ?? .comfortable
        self.density = d
        self.accentHex = defaults.string(forKey: Key.accent)

        // Sync the global lookup so `Theme.Color.*` tokens resolve against
        // the persisted theme on first read, before any view subscribes.
        Theme.currentTheme = named
    }

    // MARK: - Preset swatches

    public struct Swatch: Sendable, Identifiable, Equatable {
        public let id: String
        public let label: String
        public let hex: String
        public init(id: String, label: String, hex: String) {
            self.id = id; self.label = label; self.hex = hex
        }

        public var color: Color {
            guard let rgb = AppearanceStore.decodeHex(hex) else { return .clear }
            return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
        }
    }

    /// Eight preset accents spanning the color wheel. Hex values approximate
    /// the OKLCH hues documented in the plan (coral 28, blue 250, green 145,
    /// purple 300, amber 75, cyan 200, orange 30, teal 180) at ~72% L / 0.18 C.
    public static let presets: [Swatch] = [
        Swatch(id: "coral",  label: "Coral",  hex: "#F4866A"),
        Swatch(id: "blue",   label: "Blue",   hex: "#6D94E8"),
        Swatch(id: "green",  label: "Green",  hex: "#56BF6E"),
        Swatch(id: "purple", label: "Purple", hex: "#B074E2"),
        Swatch(id: "amber",  label: "Amber",  hex: "#D7AF47"),
        Swatch(id: "cyan",   label: "Cyan",   hex: "#4BAFC6"),
        Swatch(id: "orange", label: "Orange", hex: "#EE8253"),
        Swatch(id: "teal",   label: "Teal",   hex: "#3FB7A4"),
    ]

    // MARK: - Hex helpers

    /// Decodes `#RRGGBB` or `RRGGBB` into sRGB 0..1 components.
    public nonisolated static func decodeHex(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8)  & 0xFF) / 255.0
        let b = Double( value        & 0xFF) / 255.0
        return (r, g, b)
    }

    /// Encodes a SwiftUI Color to `#RRGGBB` via NSColor bridging. Best-effort , 
    /// returns nil for extended-gamut colors that can't be squashed to sRGB.
    public static func encodeHex(_ color: Color) -> String? {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        guard let c = ns else { return nil }
        let r = Int((c.redComponent   * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent  * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: - Reset

    /// Restore Plan 01.5 defaults; coral accent, auto theme, comfortable density.
    public func resetToDefaults() {
        themeMode = .auto
        theme = .darkChronicle
        accentHex = nil
        density = .comfortable
    }
}

// MARK: - Environment

private struct DensityScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

public extension EnvironmentValues {
    /// Current density padding multiplier. Reads 1.0 by default, so views
    /// that don't opt in stay on the Plan 01.5 layout.
    var densityScale: Double {
        get { self[DensityScaleKey.self] }
        set { self[DensityScaleKey.self] = newValue }
    }
}
