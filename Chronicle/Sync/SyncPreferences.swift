import SwiftUI
import Combine
import Foundation

/// Settings store for iCloud Drive sync. Three knobs:
///  - `enabled`  → turn the periodic push + "Sync now" button on/off
///  - `lastSyncedAt` → timestamp of the most recent successful push/pull
///  - `lastSyncStatus` → short human-readable status string ("Synced", "Failed: …")
///
/// Persisted under stable UserDefaults keys so settings survive restarts.
@MainActor
public final class SyncPreferences: ObservableObject {
    public static let shared = SyncPreferences()

    public enum Key {
        public static let enabled       = "chronicle.sync.enabled"
        public static let lastSyncedAt  = "chronicle.sync.lastSyncedAt"
        public static let lastStatus    = "chronicle.sync.lastStatus"
    }

    private let defaults: UserDefaults

    @Published public var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    @Published public var lastSyncedAt: Date? {
        didSet {
            if let date = lastSyncedAt {
                defaults.set(date, forKey: Key.lastSyncedAt)
            } else {
                defaults.removeObject(forKey: Key.lastSyncedAt)
            }
        }
    }

    @Published public var lastSyncStatus: String {
        didSet { defaults.set(lastSyncStatus, forKey: Key.lastStatus) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default: enabled. Users opt out via Settings.
        if defaults.object(forKey: Key.enabled) == nil {
            self.enabled = true
        } else {
            self.enabled = defaults.bool(forKey: Key.enabled)
        }
        self.lastSyncedAt = defaults.object(forKey: Key.lastSyncedAt) as? Date
        self.lastSyncStatus = defaults.string(forKey: Key.lastStatus) ?? ""
    }

    public func recordSuccess(at date: Date = Date()) {
        lastSyncedAt = date
        lastSyncStatus = "Synced"
    }

    public func recordFailure(_ message: String) {
        lastSyncStatus = "Failed: \(message)"
    }
}

// MARK: - Editor preference observable wrapper

/// Very small store over `EditorPreference.load/save`. Exposed as an
/// ObservableObject so the Settings scene can re-render when the user
/// flips the dropdown.
@MainActor
public final class EditorPreferenceStore: ObservableObject {
    public static let shared = EditorPreferenceStore()

    @Published public var editor: Editor? {
        didSet { EditorPreference.save(editor) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.editor = EditorPreference.load(from: defaults)
    }
}
