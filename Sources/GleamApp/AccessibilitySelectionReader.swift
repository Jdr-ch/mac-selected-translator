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

    /// 先读入口保存的来源选区；润色允许在弹出面板关闭后恢复来源焦点再复制。
    @MainActor
    func readSelectedText(from application: NSRunningApplication? = nil, restoreSourceFocus: Bool = false) async throws -> String {
        if !Self.isAccessibilityTrusted(prompt: false) {
            throw TranslatorAppError.accessibilityPermissionMissing
        }

        guard let application = application ?? NSWorkspace.shared.frontmostApplication else {
            throw TranslatorAppError.noSelectedText
        }
        let capture = SelectionCapture(
            sourcePID: application.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier,
            foregroundPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            activateSource: { application.activate(options: [.activateIgnoringOtherApps]) },
            accessibilityText: {
                await Task.detached(priority: .userInitiated) {
                    Self.readViaAccessibility(processIdentifier: application.processIdentifier)
                }.value
            },
            copiedText: {
                let task = Task.detached(priority: .userInitiated) {
                    Self.readViaCopyShortcut(sourcePID: application.processIdentifier)
                }
                return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
            }
        )
        return try await capture.read(restoreSourceFocus: restoreSourceFocus)
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

    /// 复制前再次核对焦点和取消状态，缩小异步恢复焦点与发送键盘事件之间的竞态。
    private static func readViaCopyShortcut(sourcePID: pid_t) -> String? {
        guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return nil }
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

/// 可注入系统边界的选区流程，测试焦点恢复及第三应用切换时无需操作用户桌面。
@MainActor
struct SelectionCapture {
    let sourcePID: pid_t
    let ownPID: pid_t
    let foregroundPID: () -> pid_t?
    let activateSource: () -> Bool
    let accessibilityText: () async -> String?
    let copiedText: () async -> String?
    var waitForFocus: () async throws -> Void = { try await Task.sleep(nanoseconds: 25_000_000) }

    /// 只接受来源应用或拾光仍在前台的捕获上下文，用户切走后不再抢回焦点。
    func read(restoreSourceFocus: Bool) async throws -> String {
        try Task.checkCancellation()
        try checkContext()
        let accessible = await accessibilityText()
        try Task.checkCancellation()
        try checkContext()
        if let text = cleaned(accessible) { return text }

        if foregroundPID() == ownPID, sourcePID != ownPID, restoreSourceFocus {
            guard activateSource() else { throw TranslatorAppError.noSelectedText }
            // macOS 激活是异步的；等待最多 500ms，期间第三应用获得焦点即终止。
            for _ in 0..<20 {
                try Task.checkCancellation()
                try checkContext()
                if foregroundPID() == sourcePID { break }
                try await waitForFocus()
            }
        }
        try Task.checkCancellation()
        guard foregroundPID() == sourcePID else { throw TranslatorAppError.noSelectedText }
        let copied = await copiedText()
        try Task.checkCancellation()
        guard foregroundPID() == sourcePID, let text = cleaned(copied) else { throw TranslatorAppError.noSelectedText }
        return text
    }

    private func checkContext() throws {
        guard let current = foregroundPID(), current == sourcePID || current == ownPID else {
            throw TranslatorAppError.noSelectedText
        }
    }

    /// 空白 AX 结果继续走复制回退；复制失败返回空时绝不读取历史剪贴板。
    private func cleaned(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
