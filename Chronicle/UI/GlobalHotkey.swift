import Foundation
import Carbon.HIToolbox

/// Thin wrapper around macOS Carbon's `RegisterEventHotKey` API for
/// app-global keyboard shortcuts. Use this when you need a shortcut to
/// fire even when Chronicle isn't frontmost. SwiftUI's `.keyboardShortcut`
/// only works when a view of the app has focus.
///
/// ## Lifetime
///
/// The hotkey is unregistered automatically when the instance is
/// deinitialised. Create one instance per binding and keep it alive for as
/// long as you want the shortcut to work.
///
/// ## Example
///
/// ```
/// let toggle = GlobalHotkey(
///     key: .o,
///     modifiers: [.command, .shift],
///     handler: { await openMenubar() }
/// )
/// try toggle.register()
/// ```
public final class GlobalHotkey: @unchecked Sendable {
    // MARK: - Errors

    public enum RegisterError: Error, LocalizedError {
        case registrationFailed(OSStatus)
        case alreadyRegistered

        public var errorDescription: String? {
            switch self {
            case .registrationFailed(let status):
                return "Carbon RegisterEventHotKey failed with OSStatus \(status)"
            case .alreadyRegistered:
                return "This GlobalHotkey is already registered; call unregister() first."
            }
        }
    }

    // MARK: - Shared dispatcher

    /// Unique ID counter; every new hotkey gets a fresh integer. Carbon
    /// addresses hotkeys by the `EventHotKeyID.id` field which we use as an
    /// index into `registry`.
    private static let nextID = Atomic<UInt32>(1)

    /// Running registry of handler callbacks, keyed by `EventHotKeyID.id`.
    /// Protected by `registryLock`, the Carbon event handler can fire on
    /// any thread, and the lifecycle methods run on the main actor.
    nonisolated(unsafe) private static var registry: [UInt32: @Sendable () -> Void] = [:]
    private static let registryLock = NSLock()

    /// Our app's Chronicle fourCC signature, used as `EventHotKeyID.signature`.
    /// Equivalent to fourCC('CHRN').
    private static let signature: OSType = 0x4348524E

    /// The one InstallEventHandler we keep alive for the life of the app.
    /// Set lazily on the first `register()` call.
    nonisolated(unsafe) private static var eventHandlerRef: EventHandlerRef?

    // MARK: - Instance

    public let key: Key
    public let modifiers: Modifiers
    public let handler: @Sendable () -> Void
    private let id: UInt32

    private var hotKeyRef: EventHotKeyRef?

    public init(
        key: Key,
        modifiers: Modifiers,
        handler: @escaping @Sendable () -> Void
    ) {
        self.key = key
        self.modifiers = modifiers
        self.handler = handler
        self.id = Self.nextID.increment()
    }

    deinit {
        try? self.unregister()
    }

    /// Register the hotkey with Carbon. Idempotent in the sense that calling
    /// it twice in a row throws `.alreadyRegistered`, unregister first.
    @discardableResult
    public func register() throws -> Self {
        guard hotKeyRef == nil else { throw RegisterError.alreadyRegistered }

        // Lazily install the dispatcher the first time any hotkey registers.
        try Self.installDispatcherIfNeeded()

        // Stash the handler in the registry BEFORE the hotkey exists, so
        // there's no race where the OS fires the shortcut on a missing entry.
        Self.registryLock.lock()
        Self.registry[id] = handler
        Self.registryLock.unlock()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            key.rawValue,
            modifiers.rawValue,
            hotKeyID,
            GetApplicationEventTarget(),
            0, // options, unused
            &ref
        )
        if status != noErr {
            Self.registryLock.lock()
            Self.registry.removeValue(forKey: id)
            Self.registryLock.unlock()
            throw RegisterError.registrationFailed(status)
        }
        self.hotKeyRef = ref
        return self
    }

    /// Unregister the hotkey. Safe to call repeatedly; only the first call
    /// does work.
    public func unregister() throws {
        Self.registryLock.lock()
        Self.registry.removeValue(forKey: id)
        Self.registryLock.unlock()

        if let ref = hotKeyRef {
            let status = UnregisterEventHotKey(ref)
            self.hotKeyRef = nil
            if status != noErr {
                throw RegisterError.registrationFailed(status)
            }
        }
    }

    // MARK: - Dispatcher

    private static func installDispatcherIfNeeded() throws {
        if eventHandlerRef != nil { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The callback has to be a C function pointer; retrieve the handler
        // from the registry by looking up the EventHotKeyID in the event.
        let callback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            GlobalHotkey.registryLock.lock()
            let handler = GlobalHotkey.registry[hotKeyID.id]
            GlobalHotkey.registryLock.unlock()

            handler?()
            return noErr
        }

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            nil,
            &handlerRef
        )
        if status != noErr {
            throw RegisterError.registrationFailed(status)
        }
        self.eventHandlerRef = handlerRef
    }
}

// MARK: - Key + Modifier types

public extension GlobalHotkey {

    /// A Carbon `kVK_*` virtual keycode. Add cases as we need them; there's
    /// no reason to surface every key from the USB HID table until something
    /// uses them.
    enum Key: UInt32 {
        case o          = 0x1F  // kVK_ANSI_O
        case returnKey  = 0x24  // kVK_Return
        case space      = 0x31  // kVK_Space
        case c          = 0x08  // kVK_ANSI_C
        case n          = 0x2D  // kVK_ANSI_N
    }

    /// Modifier flags corresponding to `cmdKey / shiftKey / optionKey /
    /// controlKey` from Carbon. The OptionSet wrapper lets callers write
    /// `[.command, .shift]` like a SwiftUI shortcut.
    struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: UInt32(cmdKey))
        public static let shift   = Modifiers(rawValue: UInt32(shiftKey))
        public static let option  = Modifiers(rawValue: UInt32(optionKey))
        public static let control = Modifiers(rawValue: UInt32(controlKey))
    }
}

// MARK: - Tiny Atomic helper

/// Minimal atomic counter backed by `NSLock`. Chosen over `OSAtomic*`
/// (deprecated) and `ManagedAtomic` (requires Swift Atomics package) so we
/// stay dependency-free per the plan's constraints.
private final class Atomic<Value: FixedWidthInteger & Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ initial: Value) { self.value = initial }

    func increment() -> Value {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}
