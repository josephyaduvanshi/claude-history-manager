import XCTest
import SwiftUI
@testable import Chronicle

/// Verifies that Theme's OKLCH→sRGB converter produces values close to
/// reference conversions. Not a pixel-exact test (SwiftUI.Color stores
/// values opaquely); instead we verify the converter doesn't crash and
/// produces in-range sRGB triples for a handful of spec colors.
final class ThemeTests: XCTestCase {

    // MARK: - OKLCH converter smoke tests

    /// Flutter dot — oklch(70% 0.12 250) should land in the blue region
    /// (b > r + 0.3, g in mid range).
    func test_oklchColor_flutter_landsInBlue() {
        let c = Theme.Color.oklchColor(l: 0.70, c: 0.12, h: 250)
        let rgb = c.resolvedRGB()
        XCTAssertGreaterThan(rgb.blue, rgb.red + 0.3,
            "flutter should be visibly blue: \(rgb)")
        XCTAssertLessThan(rgb.red, 0.5)
        XCTAssertGreaterThan(rgb.blue, 0.7)
    }

    /// Security dot — oklch(72% 0.14 145) should land in the green region.
    func test_oklchColor_security_landsInGreen() {
        let c = Theme.Color.oklchColor(l: 0.72, c: 0.14, h: 145)
        let rgb = c.resolvedRGB()
        XCTAssertGreaterThan(rgb.green, rgb.red + 0.2,
            "security should be visibly green: \(rgb)")
        XCTAssertGreaterThan(rgb.green, rgb.blue + 0.2)
        XCTAssertGreaterThan(rgb.green, 0.6)
    }

    /// Out-of-gamut OKLCH values should clamp to [0,1] without producing
    /// NaNs or negative components.
    func test_oklchColor_clampsOutOfGamut() {
        // Very high chroma at red hue — some linear components go negative.
        let c = Theme.Color.oklchColor(l: 0.5, c: 0.6, h: 20)
        let rgb = c.resolvedRGB()
        XCTAssertTrue((0...1).contains(rgb.red), "red should be clamped, got \(rgb.red)")
        XCTAssertTrue((0...1).contains(rgb.green), "green should be clamped, got \(rgb.green)")
        XCTAssertTrue((0...1).contains(rgb.blue), "blue should be clamped, got \(rgb.blue)")
        XCTAssertFalse(rgb.red.isNaN)
    }

    /// Zero-chroma OKLCH (pure gray) should produce r ≈ g ≈ b.
    func test_oklchColor_zeroChroma_producesGray() {
        let c = Theme.Color.oklchColor(l: 0.5, c: 0.0, h: 0)
        let rgb = c.resolvedRGB()
        XCTAssertEqual(rgb.red, rgb.green, accuracy: 0.02)
        XCTAssertEqual(rgb.green, rgb.blue, accuracy: 0.02)
    }

    // MARK: - dotColor mapping

    /// Unknown group should fall back to textMuted, not crash.
    func test_dotColor_unknownGroup_fallsBackToMuted() {
        let c = Theme.Color.dotColor(forGroup: "nonexistent")
        let fallback = Theme.Color.textMuted
        XCTAssertEqual(c.resolvedRGB().red, fallback.resolvedRGB().red, accuracy: 0.01)
    }
}

// MARK: - Helpers

/// Resolves a SwiftUI.Color back to its sRGB components for testing.
/// Uses NSColor bridging since SwiftUI.Color doesn't expose its triple
/// directly before macOS 14.
private extension SwiftUI.Color {
    func resolvedRGB() -> (red: Double, green: Double, blue: Double) {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? NSColor.black
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
    }
}
