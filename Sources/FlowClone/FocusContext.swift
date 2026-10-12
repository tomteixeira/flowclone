import AppKit
import ApplicationServices
import FlowCore

/// Snapshot of where the user is typing, taken when dictation starts.
/// Same shape as Wispr Flow's `TextBoxInfoPayload` (beforeText, selectedText,
/// afterText, isEditable) + `AppInfoUpdatePayload` (appName, bundleId), which its
/// helper reads via AXUIElementCopyAttributeValue on AXFocusedUIElement.
struct FocusContext {
    var appName: String?
    var bundleID: String?
    var beforeText = ""
    var selectedText = ""
    var afterText = ""
    var isEditable = false

    var category: AppCategory { AppCategory.from(bundleID: bundleID) }

    static func capture(maxChars: Int = 2000) -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var ctx = FocusContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier)

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25) // never hang on an unresponsive app
        guard let focused: AXUIElement = copy(system, kAXFocusedUIElementAttribute) else { return ctx }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success {
            ctx.isEditable = settable.boolValue
        }
        guard let value: String = copy(focused, kAXValueAttribute) else { return ctx }
        let ns = value as NSString

        var range = CFRange(location: ns.length, length: 0)
        if let axRange: AXValue = copy(focused, kAXSelectedTextRangeAttribute) {
            AXValueGetValue(axRange, .cfRange, &range)
        }
        let loc = max(0, min(range.location, ns.length))
        let len = max(0, min(range.length, ns.length - loc))
        let beforeStart = max(0, loc - maxChars)
        ctx.beforeText = ns.substring(with: NSRange(location: beforeStart, length: loc - beforeStart))
        ctx.selectedText = ns.substring(with: NSRange(location: loc, length: len))
        let afterStart = loc + len
        ctx.afterText = ns.substring(with: NSRange(location: afterStart, length: min(maxChars, ns.length - afterStart)))
        return ctx
    }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
