import SwiftUI
import AppKit

/// Renders a `ProviderID`'s brand glyph as a tinted vector image.
///
/// Loads the PDF shipped under `Chronicle/Resources/ProviderIcons/<name>.pdf`
/// by walking a list of candidate bundle locations and reading the
/// file directly off disk. Returns the loaded `NSImage` wrapped as
/// a SwiftUI `Image` with `.template` rendering so the active theme
/// tints it.
///
/// Why direct file access (not `Bundle.module`):
/// `Bundle.module` is the SwiftPM-generated synthetic accessor for
/// the per-target resource bundle. In a `.app` shipped to a user,
/// `Bundle.module` lazily evaluates `Bundle(url:)` against several
/// candidate paths and asserts via `preconditionFailure` if none
/// resolve. Under macOS's app-translocation security feature
/// (which fires when a quarantined `.app` is opened from
/// `/Applications` for the first time before quarantine is stripped),
/// `Bundle(url:)` can return nil for the resource bundle even though
/// the bundle is present at the expected path inside the translocated
/// copy. The assertion crashes the app on first launch, before the
/// in-app `QuarantineDetector` card has a chance to show. v0.2.1
/// shipped with this dependency on `Bundle.module` and crashed at
/// `ProviderIconView.body.getter` on quarantined first-launches.
///
/// The implementation here looks for the PDF on disk via
/// `FileManager` directly, with no `Bundle(url:)` lookup, so a
/// missing resource just causes the SF Symbol fallback to render
/// instead of crashing the process.
///
/// Falls back to the SF Symbol named by `id.iconSymbol` when the PDF
/// can't be located — e.g. running against a stale build product, or
/// in a future test harness where the resource bundle isn't packaged.
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

    /// Resolve `<name>.pdf` by walking candidate paths on disk.
    /// Returns nil rather than asserting if no candidate resolves —
    /// the `body` view falls through to an SF Symbol so the UI
    /// degrades visually instead of crashing the process.
    private static func loadPDF(named name: String) -> NSImage? {
        let fm = FileManager.default
        let mainBundleURL = Bundle.main.bundleURL
        let mainResourceURL = Bundle.main.resourceURL ?? mainBundleURL
        let bundleNames = ["Chronicle_Chronicle.bundle"]

        // Build a list of plausible paths to the PDF. Some entries
        // expect the SwiftPM-style flat resource bundle; others
        // anticipate a future move to an Asset Catalog or an
        // Xcode-built bundle layout. Evaluating each as a plain
        // file path means we never trigger Bundle(url:)'s
        // assertion on a malformed resource bundle.
        var candidates: [URL] = []
        for bundleName in bundleNames {
            let bundle = mainBundleURL
                .appendingPathComponent("Contents/Resources/")
                .appendingPathComponent(bundleName)
            candidates.append(bundle.appendingPathComponent("\(name).pdf"))
            candidates.append(bundle.appendingPathComponent("ProviderIcons/\(name).pdf"))
        }
        // Direct app/Resources fallbacks — covers test runs and any
        // future change that drops the SwiftPM bundle wrapper.
        candidates.append(mainResourceURL.appendingPathComponent("\(name).pdf"))
        candidates.append(mainResourceURL.appendingPathComponent("ProviderIcons/\(name).pdf"))

        for url in candidates where fm.fileExists(atPath: url.path) {
            if let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }
}
