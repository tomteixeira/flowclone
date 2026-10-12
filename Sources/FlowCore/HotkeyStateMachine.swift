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

/// What the state machine tells its owner.
public enum HotkeyOutput: Equatable, Sendable {
    case press
    case release
    /// Another key was used while holding the push-to-talk key: a shortcut, not dictation.
    case interrupt
}

/// Pure interpretation of key events for push-to-talk. Each event yields zero or
/// more outputs, so later rules can emit several at once.
public struct HotkeyStateMachine: Sendable {
    public let key: PushToTalkKey
    private var isDown = false
    private var interrupted = false

    public init(key: PushToTalkKey) { self.key = key }

    public mutating func handle(_ event: KeyEvent) -> [HotkeyOutput] {
        switch event {
        case .keyDown:
            return interrupt()
        case let .flagsChanged(keycode, flags):
            // Another modifier while holding ours (e.g. ⌥⇧) also means a shortcut.
            guard keycode == key.keycode else { return interrupt() }
            let down = key.isDown(flags: flags)
            guard down != isDown else { return [] }
            isDown = down
            if down {
                interrupted = false
                return [.press]
            }
            return interrupted ? [] : [.release]
        }
    }

    /// The first interruption of a hold is reported once; the release is then swallowed.
    private mutating func interrupt() -> [HotkeyOutput] {
        guard isDown, !interrupted else { return [] }
        interrupted = true
        return [.interrupt]
    }
}
