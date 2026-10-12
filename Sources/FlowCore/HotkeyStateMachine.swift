/// The push-to-talk keys. Raw values are persisted in UserDefaults.
public enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightCommand, rightOption, fn

    public var keycode: Int64 {
        switch self {
        case .rightCommand: 54 // kVK_RightCommand
        case .rightOption: 61  // kVK_RightOption
        case .fn: 63           // kVK_Function
        }
    }

    /// Whether the key is down given the raw `CGEventFlags` bits. Device-dependent
    /// bits (NX_DEVICERCMDKEYMASK, NX_DEVICERALTKEYMASK) tell the right-hand key
    /// apart from the left one; Fn uses `maskSecondaryFn`.
    public func isDown(flags: UInt64) -> Bool {
        switch self {
        case .rightCommand: flags & 0x10 != 0
        case .rightOption: flags & 0x40 != 0
        case .fn: flags & 0x800000 != 0
        }
    }
}

/// A keyboard event reduced to what the state machine needs.
public enum KeyEvent: Equatable, Sendable {
    /// A modifier changed: its keycode and the raw `CGEventFlags` bits after the change.
    case flagsChanged(keycode: Int64, flags: UInt64)
    /// Any non-modifier key went down.
    case keyDown
}

/// What a push-to-talk session does with the speech: dictate it, or treat it as
/// an instruction (Command Mode, Shift + the push-to-talk key).
public enum SessionMode: Equatable, Sendable {
    case dictation, command
}

/// What the state machine tells its owner.
public enum HotkeyOutput: Equatable, Sendable {
    /// The key went down; `.command` when Shift was already held.
    case press(mode: SessionMode)
    /// Shift joined a hold that started as dictation (the HUD changes look).
    case modeChanged(SessionMode)
    case release(mode: SessionMode)
    /// Another key was used while holding the push-to-talk key: a shortcut, not dictation.
    case interrupt
}

/// Pure interpretation of key events for push-to-talk. Each event yields zero or
/// more outputs, to be handled in order.
public struct HotkeyStateMachine: Sendable {
    public let key: PushToTalkKey
    private var isDown = false
    private var interrupted = false
    private var mode = SessionMode.dictation

    /// Shift's keycodes (kVK_Shift, kVK_RightShift) and its device-independent flag.
    private static let shiftKeycodes: Set<Int64> = [56, 60]
    private static let shiftFlag: UInt64 = 0x20000

    public init(key: PushToTalkKey) { self.key = key }

    public mutating func handle(_ event: KeyEvent) -> [HotkeyOutput] {
        switch event {
        case .keyDown:
            return interrupt()
        case let .flagsChanged(keycode, flags):
            if Self.shiftKeycodes.contains(keycode) { return shiftChanged(flags: flags) }
            // Another modifier while holding ours (e.g. ⌥⌘) also means a shortcut.
            guard keycode == key.keycode else { return interrupt() }
            let down = key.isDown(flags: flags)
            guard down != isDown else { return [] }
            isDown = down
            if down {
                interrupted = false
                // Shift already held when the key goes down also means Command Mode.
                mode = flags & Self.shiftFlag != 0 ? .command : .dictation
                return [.press(mode: mode)]
            }
            return interrupted ? [] : [.release(mode: mode)]
        }
    }

    /// Shift pressed during a hold switches it to Command Mode for good; releasing
    /// Shift changes nothing, the switch is sticky until the key is released.
    private mutating func shiftChanged(flags: UInt64) -> [HotkeyOutput] {
        guard isDown, !interrupted, mode == .dictation, flags & Self.shiftFlag != 0 else { return [] }
        mode = .command
        return [.modeChanged(.command)]
    }

    /// The first interruption of a hold is reported once; the release is then swallowed.
    private mutating func interrupt() -> [HotkeyOutput] {
        guard isDown, !interrupted else { return [] }
        interrupted = true
        return [.interrupt]
    }
}
