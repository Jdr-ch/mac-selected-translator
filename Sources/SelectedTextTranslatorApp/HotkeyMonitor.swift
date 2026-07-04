import AppKit

final class HotkeyMonitor {
    private let onTrigger: () -> Void
    private let doublePressInterval: TimeInterval = 0.75
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastShiftFTime: TimeInterval = 0

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    /// Starts listening for the Shift+F, Shift+F sequence globally.
    ///
    /// macOS does not treat "Shift+F+F" as a single native shortcut. This
    /// monitor interprets it as two non-repeated Shift+F keyDown events within a
    /// short window, which matches the requested gesture without intercepting
    /// normal typing in the foreground application.
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
        let onlyShift = flags.contains(.shift)
            && !flags.contains(.command)
            && !flags.contains(.control)
            && !flags.contains(.option)
        guard onlyShift, event.charactersIgnoringModifiers?.lowercased() == "f" else {
            return
        }

        let now = event.timestamp
        if now - lastShiftFTime <= doublePressInterval {
            lastShiftFTime = 0
            DispatchQueue.main.async { [onTrigger] in
                onTrigger()
            }
        } else {
            lastShiftFTime = now
        }
    }

    deinit {
        stop()
    }
}
