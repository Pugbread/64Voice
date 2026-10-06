import ApplicationServices
import Foundation

/// Peeks at the focused text field so back-to-back dictations don't run together ("one.Two").
enum CaretContext {
    /// True when the character right before the caret is visible text and `text` doesn't start
    /// with punctuation. Returns false whenever the field can't be read.
    static func needsLeadingSpace(before text: String) -> Bool {
        guard let first = text.first, !first.isPunctuation else { return false }
        guard let previous = characterBeforeCaret() else { return false }
        return !previous.isWhitespace && !"([{\"'“‘/-".contains(previous)
    }

    private static func characterBeforeCaret() -> Character? {
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.05)

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else { return nil }
        let focused = focusedValue as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.05)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &selection), selection.location > 0 else { return nil }

        var previousRange = CFRange(location: selection.location - 1, length: 1)
        guard let previousRangeValue = AXValueCreate(.cfRange, &previousRange) else { return nil }
        var stringValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            focused,
            kAXStringForRangeParameterizedAttribute as CFString,
            previousRangeValue,
            &stringValue
        ) == .success,
            let string = stringValue as? String
        else { return nil }
        return string.last
    }
}
