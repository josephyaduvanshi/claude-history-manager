import XCTest
@testable import Chronicle

final class ProviderSwitcherTests: XCTestCase {

    @MainActor
    func test_switchTo_noOpWhenAlreadyActive() {
        let state = AppState()
        state.availableProviders = [.claude, .codex]
        state.activeProvider = .claude
        var reloaded = false
        state.switchTo(.claude, repository: nil) { reloaded = true }
        XCTAssertEqual(state.activeProvider, .claude)
        XCTAssertFalse(reloaded, "Switching to the already-active provider must not fire reload")
    }

    @MainActor
    func test_switchTo_ignoresUnavailableProvider() {
        let state = AppState()
        state.availableProviders = [.claude]
        state.activeProvider = .claude
        var reloaded = false
        state.switchTo(.codex, repository: nil) { reloaded = true }
        XCTAssertEqual(state.activeProvider, .claude,
                       "Switching to a provider not in availableProviders is rejected")
        XCTAssertFalse(reloaded)
    }

    @MainActor
    func test_switchTo_changesProviderAndCallsReload() {
        let state = AppState()
        state.availableProviders = [.claude, .codex, .gemini]
        state.activeProvider = .claude
        var reloaded = false
        state.switchTo(.codex, repository: nil) { reloaded = true }
        XCTAssertEqual(state.activeProvider, .codex)
        XCTAssertTrue(reloaded, "switchTo to a fresh provider must fire reload")
    }

    @MainActor
    func test_switchTo_persistsToUserDefaults() {
        let suiteName = "test.chronicle.providerSwitcher.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create test UserDefaults"); return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = AppState()
        state.availableProviders = [.claude, .codex]
        state.activeProvider = .claude
        // Use the saveActiveProviderToDefaults call through switchTo.
        state.switchTo(.codex)
        // switchTo writes to .standard; verify by reading back into a
        // fresh state.
        let fresh = AppState()
        fresh.loadActiveProviderFromDefaults()
        XCTAssertEqual(fresh.activeProvider, .codex)
        // Restore default for other tests.
        UserDefaults.standard.removeObject(forKey: AppState.activeProviderDefaultsKey)
    }

    @MainActor
    func test_loadActiveProviderFromDefaults_handlesUnknownValue() {
        let suiteName = "test.chronicle.providerLoader.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail(); return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("aider", forKey: AppState.activeProviderDefaultsKey)
        let state = AppState()
        state.activeProvider = .codex
        state.loadActiveProviderFromDefaults(defaults)
        XCTAssertEqual(state.activeProvider, .codex,
                       "Unknown provider strings in defaults are ignored, leaving the field unchanged")
    }

    @MainActor
    func test_loadActiveProviderFromDefaults_restoresValidValue() {
        let suiteName = "test.chronicle.providerLoaderValid.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail(); return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("gemini", forKey: AppState.activeProviderDefaultsKey)
        defaults.set(["claude", "gemini"], forKey: AppState.bootstrappedProvidersDefaultsKey)
        // The bootstrap-data version mechanism (Bug 3) drops any
        // persisted bootstrappedProviders set when the persisted version
        // is older than the current build expects. Stamp the current
        // version so this restoration test exercises the steady-state
        // path rather than the upgrade path.
        defaults.set(
            Chronicle.bootstrapDataVersion,
            forKey: AppState.bootstrapDataVersionDefaultsKey
        )
        let state = AppState()
        state.loadActiveProviderFromDefaults(defaults)
        XCTAssertEqual(state.activeProvider, .gemini)
        XCTAssertEqual(state.bootstrappedProviders, [.claude, .gemini])
        XCTAssertFalse(
            state.bootstrapDataVersionUpgraded,
            "Upgrade flag must stay false when persisted version matches the build"
        )
    }

    /// Bug 3: when the persisted `bootstrapDataVersion` is older than the
    /// build expects, the loader should drop the bootstrappedProviders set
    /// so AppView re-bootstraps every provider on first switch and
    /// repopulates `file_path` for Codex / Gemini rows.
    @MainActor
    func test_loadActiveProviderFromDefaults_dropsBootstrappedSetOnVersionUpgrade() {
        let suiteName = "test.chronicle.providerLoaderUpgrade.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail(); return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("gemini", forKey: AppState.activeProviderDefaultsKey)
        defaults.set(["claude", "gemini"], forKey: AppState.bootstrappedProvidersDefaultsKey)
        // Persist a version that's strictly less than the current build's
        // `Chronicle.bootstrapDataVersion`. Using 0 keeps the test stable
        // even when the constant is bumped further in the future.
        defaults.set(0, forKey: AppState.bootstrapDataVersionDefaultsKey)

        let state = AppState()
        state.loadActiveProviderFromDefaults(defaults)
        XCTAssertEqual(state.activeProvider, .gemini,
                       "activeProvider still restores even on version upgrade")
        XCTAssertTrue(
            state.bootstrappedProviders.isEmpty,
            "bootstrappedProviders should be cleared so AppView re-runs the per-provider walker"
        )
        XCTAssertTrue(
            state.bootstrapDataVersionUpgraded,
            "Upgrade flag should fire so AppView can run the one-shot row cleanup"
        )
    }
}
