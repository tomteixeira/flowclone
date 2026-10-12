import XCTest
@testable import FlowCore

final class HotkeyStateMachineTests: XCTestCase {
    // Raw flag bits as CGEventFlags reports them.
    private let rightCmd: UInt64 = 0x100000 | 0x10
    private let leftCmd: UInt64 = 0x100000 | 0x08

    private func run(_ key: PushToTalkKey, _ events: [KeyEvent]) -> [HotkeyOutput] {
        var machine = HotkeyStateMachine(key: key)
        return events.flatMap { machine.handle($0) }
    }

    func testPressThenReleaseGivesPressRelease() {
        let out = run(.rightCommand, [
            .flagsChanged(keycode: 54, flags: rightCmd),
            .flagsChanged(keycode: 54, flags: 0),
        ])
        XCTAssertEqual(out, [.press, .release])
    }

    func testKeyDownWhileHeldInterruptsAndSuppressesRelease() {
        let out = run(.rightCommand, [
            .flagsChanged(keycode: 54, flags: rightCmd),
            .keyDown, // ⌘C
            .keyDown,
            .flagsChanged(keycode: 54, flags: 0),
        ])
        XCTAssertEqual(out, [.press, .interrupt])
    }

    func testOtherModifierWhileHeldInterrupts() {
        let rightOpt: UInt64 = 0x80000 | 0x40
        let out = run(.rightCommand, [
            .flagsChanged(keycode: 54, flags: rightCmd),
            .flagsChanged(keycode: 61, flags: rightCmd | rightOpt),
            .flagsChanged(keycode: 61, flags: rightCmd),
            .flagsChanged(keycode: 54, flags: 0),
        ])
        XCTAssertEqual(out, [.press, .interrupt])
    }

    func testRepeatedFlagsChangedWithoutStateChangeEmitsNothing() {
        let out = run(.rightCommand, [
            .flagsChanged(keycode: 54, flags: rightCmd),
            .flagsChanged(keycode: 54, flags: rightCmd),
            .flagsChanged(keycode: 54, flags: 0),
            .flagsChanged(keycode: 54, flags: 0),
        ])
        XCTAssertEqual(out, [.press, .release])
    }

    func testKeyDownWhileNotHeldEmitsNothing() {
        XCTAssertEqual(run(.rightCommand, [.keyDown, .flagsChanged(keycode: 58, flags: 0x80000 | 0x20)]), [])
    }

    func testLeftCommandIsNotRightCommand() {
        // Holding left ⌘ then pressing right ⌘ shares the 0x100000 bit; only 0x10 counts.
        let out = run(.rightCommand, [
            .flagsChanged(keycode: 55, flags: leftCmd),
            .flagsChanged(keycode: 54, flags: leftCmd),
        ])
        XCTAssertEqual(out, [])
    }

    func testRightOptionPressRelease() {
        let out = run(.rightOption, [
            .flagsChanged(keycode: 61, flags: 0x80000 | 0x40),
            .flagsChanged(keycode: 61, flags: 0),
        ])
        XCTAssertEqual(out, [.press, .release])
    }

    func testLeftOptionIsNotRightOption() {
        let out = run(.rightOption, [.flagsChanged(keycode: 61, flags: 0x80000 | 0x20)])
        XCTAssertEqual(out, [])
    }

    func testFnPressRelease() {
        let out = run(.fn, [
            .flagsChanged(keycode: 63, flags: 0x800000),
            .flagsChanged(keycode: 63, flags: 0),
        ])
        XCTAssertEqual(out, [.press, .release])
    }

    func testNewHoldAfterInterruptedOneReleasesNormally() {
        let out = run(.rightCommand, [
            .flagsChanged(keycode: 54, flags: rightCmd),
            .keyDown,
            .flagsChanged(keycode: 54, flags: 0),
            .flagsChanged(keycode: 54, flags: rightCmd),
            .flagsChanged(keycode: 54, flags: 0),
        ])
        XCTAssertEqual(out, [.press, .interrupt, .press, .release])
    }
}
