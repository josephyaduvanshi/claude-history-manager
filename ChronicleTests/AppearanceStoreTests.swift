import XCTest
import SwiftUI
@testable import Chronicle

@MainActor
final class AppearanceStoreTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "chronicle.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: - Theme

    func test_themeMode_defaultsToAuto() {
        let store = AppearanceStore(defaults: makeDefaults())
        XCTAssertEqual(store.themeMode, .auto)
        XCTAssertNil(store.themeMode.colorScheme)
    }

    func test_themeMode_persists() {
        let d = makeDefaults()
        let a = AppearanceStore(defaults: d)
        a.themeMode = .light
        let b = AppearanceStore(defaults: d)
        XCTAssertEqual(b.themeMode, .light)
        XCTAssertEqual(b.themeMode.colorScheme, .light)
    }

    func test_themeMode_darkMapsToColorScheme() {
        let a = AppearanceStore(defaults: makeDefaults())
        a.themeMode = .dark
        XCTAssertEqual(a.themeMode.colorScheme, .dark)
    }

    // MARK: - Density

    func test_density_defaultsToComfortable() {
        let store = AppearanceStore(defaults: makeDefaults())
        XCTAssertEqual(store.density, .comfortable)
        XCTAssertEqual(store.density.paddingScale, 1.0, accuracy: 0.0001)
    }

    func test_density_paddingScaleValues() {
        XCTAssertEqual(AppearanceStore.Density.compact.paddingScale, 0.8, accuracy: 0.0001)
        XCTAssertEqual(AppearanceStore.Density.comfortable.paddingScale, 1.0, accuracy: 0.0001)
        XCTAssertEqual(AppearanceStore.Density.spacious.paddingScale, 1.2, accuracy: 0.0001)
    }

    func test_density_persists() {
        let d = makeDefaults()
        let a = AppearanceStore(defaults: d)
        a.density = .spacious
        let b = AppearanceStore(defaults: d)
        XCTAssertEqual(b.density, .spacious)
    }

    // MARK: - Accent

    func test_accent_defaultIsNilOverride() {
        let s = AppearanceStore(defaults: makeDefaults())
        XCTAssertNil(s.accentHex)
        XCTAssertNil(s.accentOverride, "no hex stored → no override")
    }

    func test_accent_overrideResolvesFromHex() {
        let s = AppearanceStore(defaults: makeDefaults())
        s.accentHex = "#6D94E8"  // blue preset
        XCTAssertNotNil(s.accentOverride)
    }

    func test_accent_persistsHex() {
        let d = makeDefaults()
        let a = AppearanceStore(defaults: d)
        a.accentHex = "#3FB7A4"
        let b = AppearanceStore(defaults: d)
        XCTAssertEqual(b.accentHex, "#3FB7A4")
    }

    func test_accent_clearRestoresDefault() {
        let d = makeDefaults()
        let a = AppearanceStore(defaults: d)
        a.accentHex = "#56BF6E"
        a.accentHex = nil
        XCTAssertNil(a.accentHex)

        // After reload, no override should remain.
        let b = AppearanceStore(defaults: d)
        XCTAssertNil(b.accentHex)
        XCTAssertNil(b.accentOverride)
    }

    // MARK: - Hex helpers

    func test_decodeHex_accepts6DigitWithAndWithoutHash() {
        let a = AppearanceStore.decodeHex("#FFFFFF")
        let b = AppearanceStore.decodeHex("000000")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertEqual(a?.r, 1.0)
        XCTAssertEqual(b?.r, 0.0)
    }

    func test_decodeHex_rejectsBadInput() {
        XCTAssertNil(AppearanceStore.decodeHex(""))
        XCTAssertNil(AppearanceStore.decodeHex("#ZZZ"))
        XCTAssertNil(AppearanceStore.decodeHex("#12345"))
    }

    // MARK: - Presets

    func test_presets_containsEightSwatches() {
        XCTAssertEqual(AppearanceStore.presets.count, 8)
        XCTAssertEqual(AppearanceStore.presets.first?.id, "coral")
    }

    // MARK: - Reset

    func test_resetToDefaults_clearsEverything() {
        let s = AppearanceStore(defaults: makeDefaults())
        s.themeMode = .light
        s.accentHex = "#B074E2"
        s.density = .compact

        s.resetToDefaults()

        XCTAssertEqual(s.themeMode, .auto)
        XCTAssertNil(s.accentHex)
        XCTAssertEqual(s.density, .comfortable)
    }
}
