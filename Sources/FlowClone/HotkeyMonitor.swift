import AppKit
import CoreGraphics
import FlowCore

extension PushToTalkKey {
    var label: String {
        switch self {
        case .rightCommand: "Right Command (⌘)"
        case .rightOption: "Right Option (⌥)"
        case .fn: "Fn (🌐)"
        }
    }
}

/// Global push-to-talk key, observed with a CGEventTap — the same mechanism
/// Wispr Flow's Swift helper uses (imports `CGEventTapCreate`, logs
/// "Caps Lock flagsChanged ignored", forwards `KeypressEvent` to Electron).
/// Modifier-only keys produce `flagsChanged` events; `keyDown`s are watched too
/// so that using the modifier in a shortcut (⌘C, ⌥[ …) isn't taken as dictation.
/// Interpreting the events is `HotkeyStateMachine`'s job (FlowCore); this class
/// only owns the tap and maps the machine's outputs to callbacks.
final class HotkeyMonitor {
    typealias Key = PushToTalkKey

    var key: Key {
        get { machine.key }
        set { machine = HotkeyStateMachine(key: newValue) }
    }
    /// The key went down; `.command` when Shift was already held.
    var onPress: (SessionMode) -> Void = { _ in }
    var onRelease: (SessionMode) -> Void = { _ in }
    /// Shift joined the hold: the session is now Command Mode.
    var onModeChanged: (SessionMode) -> Void = { _ in }
    /// Another key was pressed while holding the hotkey: it's a shortcut, not dictation.
    var onInterrupt: () -> Void = {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var machine: HotkeyStateMachine

    init(key: Key) { machine = HotkeyStateMachine(key: key) }

    /// Returns false when the tap can't be created (Accessibility not granted).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue) | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        // A listen-only tap is gated by Input Monitoring and silently receives no
        // keyboard events without it; an active tap is covered by Accessibility,
        // which we already need for reading text fields and pasting. The callback
        // passes every event through unchanged, so "active" changes nothing else.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let created = [CGEventTapOptions.defaultTap, .listenOnly].lazy.compactMap {
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: $0,
                              eventsOfInterest: mask, callback: callback, userInfo: userInfo)
        }.first
        guard let tap = created else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyEvent: KeyEvent
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables slow taps; turn ours back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        case .keyDown:
            keyEvent = .keyDown
        case .flagsChanged:
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            if keycode == key.keycode {
                log.debug("flagsChanged keycode=\(keycode) flags=\(String(event.flags.rawValue, radix: 16), privacy: .public)")
            }
            keyEvent = .flagsChanged(keycode: keycode, flags: event.flags.rawValue)
        default:
            return
        }
        let outputs = machine.handle(keyEvent)
        for output in outputs {
            switch output {
            case .press: onPress(outputs.contains(.modeChanged(.command)) ? .command : .dictation)
            case .modeChanged(let mode): onModeChanged(mode)
            case .release(let mode): onRelease(mode)
            case .interrupt: onInterrupt()
            }
        }
    }
}
