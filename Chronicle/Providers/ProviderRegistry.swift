import Foundation

/// Holds the set of providers detected as installed/usable at app launch.
/// Order is fixed (claude, codex, gemini) so the segmented control and
/// menubar tile grid render in a stable left-to-right order regardless
/// of detection order.
///
/// Constructed once from `ChronicleApp` — the registry doesn't poll;
/// availability is sampled at construction time. A future enhancement
/// could re-detect on app foreground, but for v0.2 the user is expected
/// to relaunch Chronicle after installing a new CLI.
public actor ProviderRegistry {
    private let canonicalOrder: [ProviderID] = [.claude, .codex, .gemini]
    private let byID: [ProviderID: any Provider]

    /// Build a registry from a candidate list. Only providers reporting
    /// `isAvailable() == true` are retained. The candidate order is
    /// irrelevant — `ordered()` always returns canonical order.
    public init(candidates: [any Provider]) {
        var keep: [ProviderID: any Provider] = [:]
        for p in candidates where p.isAvailable() {
            keep[type(of: p).id] = p
        }
        self.byID = keep
    }

    /// All available providers in canonical order.
    public func ordered() -> [any Provider] {
        canonicalOrder.compactMap { byID[$0] }
    }

    /// All available provider IDs in canonical order.
    public func availableIDs() -> [ProviderID] {
        canonicalOrder.filter { byID[$0] != nil }
    }

    /// Lookup by ID. Returns `nil` if the provider isn't installed/usable.
    public func provider(for id: ProviderID) -> (any Provider)? {
        byID[id]
    }

    /// Convenience: number of available providers (UI uses this to decide
    /// whether to render the switcher at all — single-provider users get
    /// a hidden switcher).
    public var count: Int { byID.count }

    public func contains(_ id: ProviderID) -> Bool { byID[id] != nil }
}
