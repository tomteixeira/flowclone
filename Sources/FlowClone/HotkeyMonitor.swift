import AppKit
import CoreGraphics

/// Global push-to-talk key, observed with a CGEventTap — the same mechanism
/// Wispr Flow's Swift helper uses (imports `CGEventTapCreate`, logs
/// "Caps Lock flagsChanged ignored", forwards `KeypressEvent` to Electron).
/// Modifier-only keys produce `flagsChanged` events; `keyDown`s are watched too
/// so that using the modifier in a shortcut (⌘C, ⌥[ …) isn't taken as dictation.
final class HotkeyMonitor {
    enum Key: String, CaseIterable {
        case rightCommand, rightOption, fn

        var keycode: Int64 {
            switch self {
            case .rightCommand: 54 // kVK_RightCommand
            case .rightOption: 61  // kVK_RightOption
            case .fn: 63           // kVK_Function
            }
        }

        var label: String {
            switch self {
            case .rightCommand: "Right Command (⌘)"
            case .rightOption: "Right Option (⌥)"
            case .fn: "Fn (🌐)"
            }
        }

        /// Device-dependent bits (NX_DEVICERCMDKEYMASK, NX_DEVICERALTKEYMASK) tell
        /// the right-hand key apart from the left one.
        func isDown(_ flags: CGEventFlags) -> Bool {
            switch self {
            case .rightCommand: flags.rawValue & 0x10 != 0
            case .rightOption: flags.rawValue & 0x40 != 0
            case .fn: flags.contains(.maskSecondaryFn)
            }
        }
    }

    var key: Key
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    /// Another key was pressed while holding the hotkey: it's a shortcut, not dictation.
    var onInterrupt: () -> Void = {}

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false
    private var interrupted = false

    init(key: Key) { self.key = key }

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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables slow taps; turn ours back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        case .keyDown:
            if isDown, !interrupted {
                interrupted = true
                onInterrupt()
            }

        case .flagsChanged:
            guard event.getIntegerValueField(.keyboardEventKeycode) == key.keycode else {
                // Another modifier while holding ours (e.g. ⌥⇧) also means a shortcut.
                if isDown, !interrupted { interrupted = true; onInterrupt() }
                return
            }
            let down = key.isDown(event.flags)
            log.debug("flagsChanged keycode=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(String(event.flags.rawValue, radix: 16), privacy: .public) down=\(down)")
            guard down != isDown else { return }
            isDown = down
            if down {
                interrupted = false
                onPress()
            } else if !interrupted {
                onRelease()
            }

        default:
            break
        }
    }
}
