import Foundation

/// App-wide constants that aren't tied to a single subsystem. Currently
/// only carries the bootstrap-data version, but the namespace is here so
/// future cross-cutting build constants don't have to invent a new top
/// level type each time.
public enum Chronicle {
    /// Monotonically increasing version of the bootstrap output format.
    /// Bumped whenever a per-provider bootstrap pass needs to repopulate
    /// columns that a SQL migration alone can't backfill (e.g. the
    /// `file_path` column added in v10, which is only populated by the
    /// Codex / Gemini bootstrap walks). Compared against the persisted
    /// `chronicle.bootstrapDataVersion` UserDefaults key on launch:
    /// if the persisted value is older, `AppState` clears
    /// `bootstrappedProviders` so every provider re-runs its walker on
    /// the next switch.
    ///
    /// History:
    ///  - 1: implicit version for v0.2.0 — Codex / Gemini bootstraps
    ///       existed but landed `file_path = NULL` due to a stale
    ///       `bootstrappedProviders` set blocking re-bootstrap (Bug 3),
    ///       and `incrementalReindex` mis-tagged Claude rows under
    ///       whatever provider was active in the segmented control
    ///       (Bug 1). Both fixed in version 2.
    ///  - 2: forces a one-shot re-bootstrap on upgrade so the
    ///       `file_path` column is populated for Codex / Gemini, and
    ///       runs a one-shot SQL cleanup that drops any
    ///       `provider IN ('codex','gemini')` workspace / session row
    ///       whose `id` doesn't carry the canonical
    ///       `<provider>:<...>` prefix.
    public static let bootstrapDataVersion: Int = 2
}
