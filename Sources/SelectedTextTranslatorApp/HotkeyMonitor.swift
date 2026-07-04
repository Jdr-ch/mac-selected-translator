import AppKit
import Carbon.HIToolbox

final class HotkeyMonitor {
    private let onTrigger: () -> Void
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    /// Starts listening for the Option+Shift+F shortcut globally.
    ///
    /// The shortcut is intentionally a single modifier chord now, so the app no
    /// longer needs to keep timing state for a double-press sequence.
    func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard !event.isARepeat else {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionShiftOnly = flags.contains(.shift)
            && flags.contains(.option)
            && !flags.contains(.command)
            && !flags.contains(.control)
        guard optionShiftOnly, event.keyCode == kVK_ANSI_F else {
            return
        }

        DispatchQueue.main.async { [onTrigger] in
            onTrigger()
        }
    }

    deinit {
        stop()
    }
}
