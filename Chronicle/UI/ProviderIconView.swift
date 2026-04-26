import SwiftUI
import AppKit

/// Renders a `ProviderID`'s brand glyph as a tinted vector image.
///
/// Loads the PDF shipped under `Chronicle/Resources/ProviderIcons/<name>.pdf`
/// via `Bundle.module` (and the Chronicle.app fallback layouts that
/// `FontLoader.resolveResourceBundle` uses). Returns the loaded
/// `NSImage` wrapped as a SwiftUI `Image` with `.template` rendering
/// so the active theme tints it.
///
/// Falls back to the SF Symbol named by `id.iconSymbol` when the PDF
/// can't be located — e.g. running against a stale build product, or
/// in a future test harness where the resource bundle isn't packaged.
/// This keeps the UI from showing an empty rectangle in any case.
///
/// Why PDF (not SVG): macOS `NSImage` natively decodes PDF and treats
/// it as an honest vector format that scales cleanly to any size and
/// participates in `.template` tinting. SwiftUI's `Image(named:bundle:)`
/// only reads SVG when the asset lives in an Asset Catalog (`.xcassets`),
/// and the SwiftPM `.process` resource pipeline doesn't currently emit
/// one. PDF skips the catalog requirement entirely.
struct ProviderIconView: View {
    let id: ProviderID
    var size: CGFloat

    var body: some View {
        if let img = Self.loadPDF(named: id.iconAssetName) {
            Image(nsImage: img)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: id.iconSymbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size, height: size)
        }
    }

    /// Look up `<name>.pdf` under `Resources/ProviderIcons/` in the
    /// process's resource bundle. Tries `Bundle.module` first (works
    /// for `swift run` / `swift test`), then the `.app` layouts used
    /// when shipped to the user (mirrors `FontLoader`).
    private static func loadPDF(named name: String) -> NSImage? {
        let candidates: [Bundle?] = [
            Bundle.module,
            Bundle(url: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Chronicle_Chronicle.bundle")),
            Bundle(url: Bundle.main.resourceURL?.appendingPathComponent("Chronicle_Chronicle.bundle") ?? Bundle.main.bundleURL),
            Bundle.main,
        ]
        for case let bundle? in candidates {
            if let url = bundle.url(
                forResource: name,
                withExtension: "pdf",
                subdirectory: "ProviderIcons"
            ) ?? bundle.url(forResource: name, withExtension: "pdf") {
                if let img = NSImage(contentsOf: url) {
                    img.isTemplate = true
                    return img
                }
            }
        }
        return nil
    }
}
