import AppKit
import Carbon.HIToolbox

final class HotkeyMonitor {
    private let onTrigger: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var fallbackGlobalMonitor: Any?
    private var fallbackLocalMonitor: Any?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    /// Starts listening for the Option+Tab shortcut globally.
    ///
    /// Carbon's `RegisterEventHotKey` is used before the NSEvent fallback
    /// because it registers an actual app-level global shortcut instead of
    /// passively observing whichever key events the foreground app exposes.
    func start() {
        let registrationStatus = registerCarbonHotKey()
        if registrationStatus != noErr {
            startFallbackMonitors()
        }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let fallbackGlobalMonitor {
            NSEvent.removeMonitor(fallbackGlobalMonitor)
        }
        if let fallbackLocalMonitor {
            NSEvent.removeMonitor(fallbackLocalMonitor)
        }

        hotKeyRef = nil
        eventHandlerRef = nil
        fallbackGlobalMonitor = nil
        fallbackLocalMonitor = nil
    }

    private func registerCarbonHotKey() -> OSStatus {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return noErr
                }

                let monitor = Unmanaged<HotkeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                DispatchQueue.main.async {
                    monitor.trigger()
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            return handlerStatus
        }

        let hotKeyID = EventHotKeyID(signature: Self.fourCharCode("MSTT"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Tab),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr, let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        return registerStatus
    }

    /// Falls back to passive key monitors when the system hotkey is unavailable.
    ///
    /// This keeps development builds usable if another app has already claimed
    /// Option+Tab, though Carbon registration remains the preferred path.
    private func startFallbackMonitors() {
        fallbackGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
        }
        fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func trigger() {
        onTrigger()
    }

    private func handle(_ event: NSEvent) {
        guard !event.isARepeat else {
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionOnly = flags.contains(.option)
            && !flags.contains(.shift)
            && !flags.contains(.command)
            && !flags.contains(.control)
        guard optionOnly, event.keyCode == kVK_Tab else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.trigger()
        }
    }

    private static func fourCharCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { result, character in
            (result << 8) + OSType(character)
        }
    }

    deinit {
        stop()
    }
}
