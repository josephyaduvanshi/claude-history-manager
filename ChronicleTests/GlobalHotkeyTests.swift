import XCTest
import Carbon.HIToolbox
@testable import Chronicle

/// Tests the pure bits of `GlobalHotkey` — the Key enum's virtual keycodes
/// and the Modifiers OptionSet math. We don't actually register a hotkey in
/// tests because Carbon's `RegisterEventHotKey` needs a running event loop
/// and steals real keystrokes from the developer's keyboard.
final class GlobalHotkeyTests: XCTestCase {

    // MARK: - Key enum

    func test_key_rawValuesMatchCarbonVirtualKeyCodes() {
        XCTAssertEqual(GlobalHotkey.Key.o.rawValue,         UInt32(kVK_ANSI_O))
        XCTAssertEqual(GlobalHotkey.Key.returnKey.rawValue, UInt32(kVK_Return))
        XCTAssertEqual(GlobalHotkey.Key.space.rawValue,     UInt32(kVK_Space))
        XCTAssertEqual(GlobalHotkey.Key.c.rawValue,         UInt32(kVK_ANSI_C))
        XCTAssertEqual(GlobalHotkey.Key.n.rawValue,         UInt32(kVK_ANSI_N))
    }

    // MARK: - Modifiers OptionSet

    func test_modifiers_commandEqualsCarbonCmdKey() {
        XCTAssertEqual(GlobalHotkey.Modifiers.command.rawValue, UInt32(cmdKey))
        XCTAssertEqual(GlobalHotkey.Modifiers.shift.rawValue,   UInt32(shiftKey))
        XCTAssertEqual(GlobalHotkey.Modifiers.option.rawValue,  UInt32(optionKey))
        XCTAssertEqual(GlobalHotkey.Modifiers.control.rawValue, UInt32(controlKey))
    }

    func test_modifiers_union() {
        let both: GlobalHotkey.Modifiers = [.command, .shift]
        XCTAssertEqual(both.rawValue, UInt32(cmdKey | shiftKey))
        XCTAssertTrue(both.contains(.command))
        XCTAssertTrue(both.contains(.shift))
        XCTAssertFalse(both.contains(.option))
    }

    func test_modifiers_empty() {
        let none: GlobalHotkey.Modifiers = []
        XCTAssertEqual(none.rawValue, 0)
    }

    // MARK: - Instance properties

    func test_init_storesKeyModifiersAndHandler() {
        let expectation = expectation(description: "handler can be stored")
        let hk = GlobalHotkey(
            key: .o,
            modifiers: [.command, .shift],
            handler: { expectation.fulfill() }
        )
        XCTAssertEqual(hk.key, .o)
        XCTAssertEqual(hk.modifiers.rawValue, UInt32(cmdKey | shiftKey))

        // Verify the stored handler is the one we passed — fire it directly
        // rather than going through Carbon (which needs a runloop).
        hk.handler()
        wait(for: [expectation], timeout: 1.0)
    }

    // MARK: - Deinit safety

    func test_deinit_doesNotCrashWhenUnregistered() {
        // Create + drop an unregistered hotkey. Deinit should be a no-op.
        _ = GlobalHotkey(key: .returnKey, modifiers: [.command, .shift], handler: {})
        // If we're still alive here, we didn't crash. Nothing else to assert.
        XCTAssertTrue(true)
    }
}
