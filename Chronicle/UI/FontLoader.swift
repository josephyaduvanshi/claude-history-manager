import CoreText
import Foundation

/// Registers Chronicle's bundled variable fonts with the process-wide
/// CTFontManager so `Font.custom("Bricolage Grotesque"...)`,
/// `Font.custom("Geist"...)` and `Font.custom("Geist Mono"...)` resolve.
/// Call once from `ChronicleApp.init`.
public enum FontLoader {
    /// Safe to call multiple times. CTFontManager returns error code 105
    /// ("already registered") which we silently ignore.
    public static func registerAll() {
        let names = ["BricolageGrotesque-VF", "Geist-Variable", "GeistMono-Variable"]
        guard let bundle = resolveResourceBundle() else {
            AppLogger.fonts.warn("could not resolve resource bundle for fonts")
            return
        }
        for name in names {
            guard let url = bundle.url(forResource: name,
                                       withExtension: "ttf",
                                       subdirectory: "Fonts")
                    ?? bundle.url(forResource: name, withExtension: "ttf") else {
                AppLogger.fonts.warn("missing bundled font: \(name).ttf")
                continue
            }
            var err: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
            if !ok, let e = err?.takeRetainedValue() {
                let code = CFErrorGetCode(e)
                // 105 == kCTFontManagerErrorAlreadyRegistered. Anything else is a real problem.
                if code != 105 {
                    AppLogger.fonts.warn("failed to register \(name): \(String(describing: e))")
                }
            }
        }
    }

    /// Bypass `Bundle.module` because its auto-generated accessor expects
    /// the resource bundle at `Bundle.main.bundleURL/Chronicle_Chronicle.bundle`,
    /// which is the wrong location for a `.app` bundle (and codesign rejects
    /// putting non-Resources files at the bundle root). Try the `.app` layout
    /// first (`Contents/Resources/Chronicle_Chronicle.bundle`), then the
    /// SwiftPM-CLI layout, then `Bundle.main` itself as a last resort for the
    /// case where fonts live directly in `Contents/Resources/Fonts/`.
    private static func resolveResourceBundle() -> Bundle? {
        let candidates: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Chronicle_Chronicle.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Chronicle_Chronicle.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Chronicle_Chronicle.bundle"),
        ].compactMap { $0 }
        for url in candidates {
            if let b = Bundle(url: url) { return b }
        }
        // Last resort: Bundle.main (fonts may be loose under Contents/Resources/).
        return Bundle.main
    }
}
