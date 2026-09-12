import XCTest
@testable import KnockCore

final class KeyComboTests: XCTestCase {
    func testParsesScreenshotShortcut() {
        let combo = KeyCombo.parse("cmd+shift+4")
        XCTAssertEqual(combo?.keyCode, 21) // kVK_ANSI_4
        XCTAssertEqual(combo?.modifiers, [.command, .shift])
    }

    func testParsesCopyShortcut() {
        let combo = KeyCombo.parse("cmd+c")
        XCTAssertEqual(combo?.keyCode, 8) // kVK_ANSI_C
        XCTAssertEqual(combo?.modifiers, [.command])
    }

    func testAcceptsAliasesCaseAndWhitespace() {
        let a = KeyCombo.parse("Command + Option + Control + Shift + Space")
        let b = KeyCombo.parse("⌘+⌥+⌃+⇧+space")
        let c = KeyCombo.parse("cmd+alt+ctrl+shift+SPACE")
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
        XCTAssertEqual(a?.modifiers, [.command, .option, .control, .shift])
    }

    func testNamedKeysAndBareKeys() {
        XCTAssertEqual(KeyCombo.parse("escape")?.keyCode, 53)
        XCTAssertEqual(KeyCombo.parse("esc")?.modifiers, [])
        XCTAssertEqual(KeyCombo.parse("cmd+left")?.keyCode, 123)
        XCTAssertEqual(KeyCombo.parse("f5")?.keyCode, 96)
    }

    func testRejectsUnknownKeyMissingKeyAndEmpty() {
        XCTAssertNil(KeyCombo.parse("cmd+bogus"))
        XCTAssertNil(KeyCombo.parse("cmd+shift"))
        XCTAssertNil(KeyCombo.parse("cmd+c+v"))
        XCTAssertNil(KeyCombo.parse(""))
    }
}
