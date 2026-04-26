import Foundation
import Sparkle
import SwiftUI

/// Thin wrapper around `SPUStandardUpdaterController`. Owns Sparkle's
/// updater for the app's lifetime so the menu item can fire
/// `checkForUpdates(_:)` against the same instance every time, and so
/// Sparkle's runloop hooks have a stable owner that doesn't churn when
/// SwiftUI re-renders.
///
/// Sparkle is configured via `Info.plist`:
/// - `SUFeedURL` points at the appcast asset on GitHub Releases
///   (`releases/latest/download/appcast.xml`).
/// - `SUPublicEDKey` is the EdDSA public key matching the private key
///   stored in the `SPARKLE_ED_PRIVATE_KEY` GitHub secret.
/// - `SUEnableInstallerLauncherService = true` lets non-sandboxed apps
///   complete the bundle swap without a privileged helper.
/// - `SUEnableAutomaticChecks = false` keeps the "no background
///   polling" promise — updates surface only when the user picks
///   "Check for updates…" from the Chronicle menu.
@MainActor
final class SparkleUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    init() {
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
