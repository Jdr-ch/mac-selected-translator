import AppKit

/// Native tool windows have no Edit menu; forward editing commands to their current field editor.
@MainActor
enum TextEditingShortcuts {
    static func perform(with event: NSEvent, in window: NSWindow) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        guard modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let actions = ["c": "copy:", "x": "cut:", "v": "paste:", "a": "selectAll:"]
        if let action = actions[key], let responder = window.firstResponder {
            return NSApp.sendAction(Selector(action), to: responder, from: window)
        }
        if key == "z", let manager = window.firstResponder?.undoManager {
            if event.modifierFlags.contains(.shift) { manager.redo() } else { manager.undo() }
            return true
        }
        return false
    }
}
