import AppKit
import ApplicationServices
import Carbon.HIToolbox

final class AccessibilitySelectionReader {
    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Reads selected text from the current foreground app.
    ///
    /// The primary path uses Accessibility's focused element selected-text
    /// attribute. Some apps do not expose that attribute consistently, so the
    /// fallback performs a temporary Command+C and restores the previous
    /// pasteboard snapshot after reading the copied string.
    func readSelectedText(from application: NSRunningApplication? = nil) async throws -> String {
        if !Self.isAccessibilityTrusted(prompt: false) {
            throw TranslatorAppError.accessibilityPermissionMissing
        }

        guard let application = application ?? NSWorkspace.shared.frontmostApplication else {
            throw TranslatorAppError.noSelectedText
        }
        let processIdentifier = application.processIdentifier
        let selectedText = await Task.detached(priority: .userInitiated) { () -> String? in
            if let text = Self.readViaAccessibility(processIdentifier: processIdentifier),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            // Never send Command+C to a different app after the source lost focus.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier else {
                return nil
            }
            return Self.readViaCopyShortcut()
        }.value

        guard let text = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw TranslatorAppError.noSelectedText
        }
        return text
    }

    private static func readViaAccessibility(processIdentifier: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var focusedValue: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        guard focusResult == .success, let focusedValue else {
            return nil
        }

        let focusedElement = focusedValue as! AXUIElement
        var selectedValue: CFTypeRef?
        let selectedResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        guard selectedResult == .success, let selectedValue else {
            return nil
        }

        if let selectedText = selectedValue as? String {
            return selectedText
        }
        if let attributedText = selectedValue as? NSAttributedString {
            return attributedText.string
        }
        return nil
    }

    private static func readViaCopyShortcut() -> String? {
        let pasteboard = NSPasteboard.general
        let snapshot = capturePasteboardItems(from: pasteboard)
        let initialChangeCount = pasteboard.changeCount

        postCommandC()
        Thread.sleep(forTimeInterval: 0.18)

        let copiedText = copiedSelection(
            pasteboard.string(forType: .string),
            before: initialChangeCount,
            after: pasteboard.changeCount
        )
        if pasteboard.changeCount != initialChangeCount {
            restorePasteboardItems(snapshot, to: pasteboard)
        }
        return copiedText
    }

    /// No clipboard mutation means copy failed; returning the old clipboard would polish unrelated text.
    static func copiedSelection(_ text: String?, before: Int, after: Int) -> String? {
        before == after ? nil : text
    }

    private static func postCommandC() {
        let keyCode = CGKeyCode(kVK_ANSI_C)
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func capturePasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else {
            return []
        }

        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restorePasteboardItems(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
