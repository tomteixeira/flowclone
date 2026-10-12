import AppKit
import ApplicationServices
import CoreGraphics

/// Inserts text into whatever app has focus, the way Wispr Flow's helper does
/// (strings in its binary: "Saved pasteboard types", "Restoring pasteboard
/// contents", `org.nspasteboard.ConcealedType`; imports CGEventPost), and then
/// checks the result through Accessibility like its `DictatedTextVerification`.
///
/// 1. snapshot the clipboard,
/// 2. put the text on it, marked concealed/transient so clipboard managers skip it,
/// 3. synthesize ⌘V,
/// 4. read the focused field back through AX: text is there → pasted, restore the
///    clipboard; field readable but text missing → leave it on the clipboard so the
///    user can paste by hand; field unreadable (many Electron apps) → assume pasted.
///
/// An earlier version promised the data lazily (NSPasteboardItemDataProvider) and used
/// "the target app asked for it" as the success signal, as Wispr does; in practice the
/// callback often didn't arrive for a windowless menu-bar app, so the text was written
/// eagerly instead.
final class Paster {
    enum Outcome: String { case pasted, unverified, leftOnClipboard }

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func paste(_ text: String, completion: @escaping (Outcome) -> Void) {
        let board = NSPasteboard.general
        let saved = Self.snapshot(board)

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealed)
        item.setData(Data(), forType: Self.transient)
        board.clearContents()
        board.writeObjects([item])
        let ourChange = board.changeCount

        let front = NSWorkspace.shared.frontmostApplication
        log.info("pasting \(text.count) chars into \(front?.bundleIdentifier ?? "?", privacy: .public); postEventAccess=\(CGPreflightPostEventAccess()) axTrusted=\(AXIsProcessTrusted())")
        Self.postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let verified = Self.focusedFieldContains(text)
            let outcome: Outcome = switch verified {
            case true?: .pasted
            case false?: .leftOnClipboard
            case nil: .unverified
            }
            // Give slow apps a moment to read the clipboard before restoring it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if outcome != .leftOnClipboard, board.changeCount == ourChange {
                    board.clearContents()
                    if !saved.isEmpty { board.writeObjects(saved) }
                }
                completion(outcome)
            }
        }
    }

    /// nil when the focused element's text can't be read.
    private static func focusedFieldContains(_ text: String) -> Bool? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        // Apps may tweak whitespace or smart quotes; compare a distinctive tail.
        let probe = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(24))
        return probe.isEmpty || string.contains(probe)
    }

    private static func snapshot(_ board: NSPasteboard) -> [NSPasteboardItem] {
        (board.pasteboardItems ?? []).map { original in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func postCommandV() {
        // .hidSystemState: start from the physical keyboard state rather than
        // the session's, so a just-released hotkey modifier doesn't leak in.
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V (same physical key on AZERTY)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
