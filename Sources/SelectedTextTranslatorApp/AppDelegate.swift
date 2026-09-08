import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let backendClient: BackendClient
    private let backendSupervisor: BackendSupervisor
    private let selectionReader = AccessibilitySelectionReader()
    private let floatingPanel = FloatingPanelController()
    private let windowLayoutController = WindowLayoutController()
    private let sleepPreventionController = SleepPreventionController()
    private let iphoneLocationWindowController: IPhoneLocationWindowController
    /// Created on first use so the diagram renderer does not delay the menu-bar app's startup.
    private var flowchartWindowController: FlowchartWindowController?
    private let polishWindowController: ContentPolishWindowController
    /// Captured before native menu tracking changes focus; never infer the source from the new panel.
    private var menuSourceApplication: NSRunningApplication?
    private var polishSelectionTask: Task<Void, Never>?
    private var hotkeyMonitor: HotkeyMonitor?
    private var statusItem: NSStatusItem?
    /// Updates the standard status-button image so AppKit can reuse it on every display's menu bar.
    private var statusIconAnimator: StatusItemIconAnimator?
    /// Intercepts only the green-light region before the status item's native menu begins tracking.
    private var statusItemMouseMonitor: Any?
    /// Retained so the status-menu label follows both the menu toggle and the green indicator.
    private var sleepMenuItem: NSMenuItem?
    /// Drives the faster icon rhythm for the lifetime of one translation request.
    private var isTranslating = false {
        didSet {
            statusIconAnimator?.animationState = isTranslating ? .translating : .idle
        }
    }

    override init() {
        let configuration = AppConfiguration()
        self.backendClient = BackendClient(configuration: configuration)
        self.backendSupervisor = BackendSupervisor(configuration: configuration)
        self.iphoneLocationWindowController = IPhoneLocationWindowController(
            projectRoot: configuration.projectRoot
        )
        let client = self.backendClient
        let supervisor = self.backendSupervisor
        self.polishWindowController = ContentPolishWindowController(session: ContentPolishSession { request in
            try await supervisor.ensureBackendRunning()
            try Task.checkCancellation()
            return try await client.polish(request)
        })
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerLaunchAtLoginIfNeeded()
        promptForAccessibilityIfNeeded()
        warmUpBackend()

        hotkeyMonitor = HotkeyMonitor { [weak self] in
            self?.handleTranslateShortcut()
        }
        hotkeyMonitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
        statusIconAnimator?.stop()
        if let statusItemMouseMonitor {
            NSEvent.removeMonitor(statusItemMouseMonitor)
        }
        iphoneLocationWindowController.shutdown()
        flowchartWindowController?.shutdown()
        polishSelectionTask?.cancel()
        polishWindowController.session.cancel()
        sleepPreventionController.restoreSystemSleep()
        backendSupervisor.terminateOwnedBackend()
    }

    private func setupStatusItem() {
        let statusBar = NSStatusBar.system
        let item = statusBar.statusItem(
            withLength: StatusItemVisualStyle.itemLength(statusBarThickness: statusBar.thickness)
        )
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "划词翻译：按 Option+Tab"
            button.setAccessibilityLabel("划词翻译")
            setupStatusIcon(in: button, statusBarThickness: statusBar.thickness)
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeMenuItem(title: "翻译当前选中文字", action: #selector(translateFromMenu)))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "整理", action: #selector(organizeWindows)))
        menu.addItem(makeMenuItem(title: "对齐", action: #selector(alignWindows)))
        let sleepMenuItem = makeMenuItem(
            title: sleepPreventionController.actionTitle,
            action: #selector(toggleSleepPrevention)
        )
        menu.addItem(sleepMenuItem)
        self.sleepMenuItem = sleepMenuItem
        sleepPreventionController.onStateChange = { [weak self] in
            self?.updateSleepPreventionUI()
        }
        sleepPreventionController.onIndicatorChange = { [weak self] in
            self?.updateStatusItemAppearance()
        }
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "iPhone 定位", action: #selector(showIPhoneLocation)))
        menu.addItem(makeMenuItem(title: "生成流程图", action: #selector(showFlowchart)))
        menu.addItem(makeMenuItem(title: "内容润色", action: #selector(showContentPolish)))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "测试弹窗", action: #selector(showTestPopover)))
        menu.addItem(makeMenuItem(title: "查看快捷键状态", action: #selector(showHotkeyStatus)))
        menu.addItem(makeMenuItem(title: "检查辅助功能权限", action: #selector(checkAccessibilityPermission)))
        menu.addItem(makeMenuItem(title: "检查/启动本地翻译服务", action: #selector(checkBackendService)))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem = item
        item.menu = menu
        installStatusItemMouseMonitor()
        updateSleepPreventionUI()
    }

    /// Starts frame rendering into the standard status-button image used by every menu-bar context.
    private func setupStatusIcon(in statusButton: NSStatusBarButton, statusBarThickness: CGFloat) {
        let animator = StatusItemIconAnimator(
            button: statusButton,
            statusBarThickness: statusBarThickness
        )
        animator.start()
        statusIconAnimator = animator
    }

    /// Lets native menu tracking handle icon clicks while consuming only active green-light clicks.
    private func installStatusItemMouseMonitor() {
        statusItemMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  self.sleepPreventionController.isPreventingSleep,
                  let button = self.statusItem?.button,
                  event.window === button.window else {
                return event
            }

            let point = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(point),
                  StatusItemVisualStyle.hitTarget(
                    at: point,
                    in: button.bounds.size,
                    isPreventingSleep: true
                  ) == .sleepIndicator else {
                return event
            }

            self.restoreSleepFromStatusIndicator()
            return nil
        }
    }

    /// Registers only a packaged app so development executables never become persistent login items.
    private func registerLaunchAtLoginIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }

        let service = SMAppService.mainApp
        guard service.status == .notRegistered else {
            return
        }

        do {
            try service.register()
        } catch {
            NSLog("Unable to register launch at login: %@", error.localizedDescription)
        }
    }

    /// Keeps the menu action and the combined status-item presentation synchronized.
    private func updateSleepPreventionUI() {
        sleepMenuItem?.title = sleepPreventionController.actionTitle
        updateStatusItemAppearance()
    }

    /// Places the pulsing green light directly left of the icon inside the stable status-item slot.
    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else {
            return
        }

        let isPreventingSleep = sleepPreventionController.isPreventingSleep
        statusIconAnimator?.isPreventingSleep = isPreventingSleep
        statusIconAnimator?.isSleepIndicatorBright = sleepPreventionController.isSleepStatusLightBright

        if isPreventingSleep {
            button.toolTip = "划词翻译；禁止休眠中：按 Option+Tab"
            button.setAccessibilityLabel("划词翻译，禁止休眠中")
        } else {
            button.toolTip = "划词翻译：按 Option+Tab"
            button.setAccessibilityLabel("划词翻译")
        }
    }

    /// Creates status-menu commands that route directly to the app delegate.
    ///
    /// Status bar menu items do not reliably find the delegate through the
    /// responder chain when their target is nil, so every command is wired to
    /// `self` explicitly to avoid silent no-op clicks.
    private func makeMenuItem(
        title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        menuItem.target = self
        return menuItem
    }

    private func promptForAccessibilityIfNeeded() {
        if !AccessibilitySelectionReader.isAccessibilityTrusted(prompt: true) {
            floatingPanel.showError("首次运行需要授予辅助功能权限，授权后请重新启动本工具。")
        }
    }

    /// Starts the backend shortly after app launch so the first hotkey feels instant.
    ///
    /// Errors are surfaced in the same floating panel used by translation
    /// failures. That gives Finder-launched `.app` users a visible reason when
    /// `.env` is missing an API key or the Python virtual environment has not
    /// been created yet.
    private func warmUpBackend() {
        Task { @MainActor in
            do {
                try await backendSupervisor.ensureBackendRunning()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                floatingPanel.showError(message)
            }
        }
    }

    /// Handles the global Option+Tab gesture.
    ///
    /// The method serializes translation requests so repeated hotkey presses do
    /// not create overlapping model calls or race the floating panel state.
    private func handleTranslateShortcut() {
        guard !isTranslating else {
            floatingPanel.showError("上一次翻译仍在进行，请稍等。")
            return
        }

        Task { @MainActor in
            await translateCurrentSelection()
        }
    }

    /// Reads the selected text, calls the local LangChain service, and renders the result.
    ///
    /// Each UI state is shown immediately near the pointer so the user can tell
    /// whether the failure happened in macOS text capture, local backend
    /// connectivity, or the remote model request.
    private func translateCurrentSelection() async {
        isTranslating = true
        floatingPanel.showLoading("正在读取选中文字...")
        defer {
            isTranslating = false
        }

        do {
            floatingPanel.showLoading("正在检查本地翻译服务...")
            try await backendSupervisor.ensureBackendRunning()
            let selectedText = try await selectionReader.readSelectedText()
            floatingPanel.showLoading("正在翻译...")
            let translation = try await backendClient.translate(selectedText, targetLanguage: "auto")
            floatingPanel.showResult(translation, sourceText: selectedText)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            floatingPanel.showError(message)
        }
    }

    @objc private func translateFromMenu() {
        handleTranslateShortcut()
    }

    /// Repositions visible windows on the screen where the status menu was opened.
    @objc private func organizeWindows() {
        performWindowLayout(windowLayoutController.organizeCurrentScreen)
    }

    /// Resizes and places visible windows into the four requested screen anchors.
    @objc private func alignWindows() {
        performWindowLayout(windowLayoutController.alignCurrentScreen)
    }

    /// Toggles the process-level sleep assertion and updates the menu action title.
    @objc private func toggleSleepPrevention() {
        sleepPreventionController.toggle()
    }

    /// Restores normal sleep immediately when the user clicks the green status light.
    @objc private func restoreSleepFromStatusIndicator() {
        guard sleepPreventionController.isPreventingSleep else {
            return
        }
        sleepPreventionController.restoreSystemSleep()
    }

    /// Runs one menu-triggered layout command and surfaces permission or window-selection failures.
    private func performWindowLayout(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            floatingPanel.showError(message)
        }
    }

    /// Opens the retained location panel so its device and simulation state survives menu dismissal.
    @objc private func showIPhoneLocation() {
        iphoneLocationWindowController.showWindow()
    }

    func menuWillOpen(_ menu: NSMenu) {
        menuSourceApplication = NSWorkspace.shared.frontmostApplication
    }

    /// Opens a retained editor instead of starting another app or replacing translation state.
    @objc private func showFlowchart() {
        if flowchartWindowController == nil {
            flowchartWindowController = FlowchartWindowController { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.backendSupervisor.ensureBackendRunning()
            }
        }
        flowchartWindowController?.showWindow()
    }

    /// Reads the source before opening the centered window, then automatically submits that selection.
    @objc private func showContentPolish() {
        guard polishSelectionTask == nil else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let sourceApplication = menuSourceApplication
        if sourceApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            polishWindowController.reveal(on: screen)
            return
        }
        polishSelectionTask = Task { @MainActor in
            defer { polishSelectionTask = nil }
            do {
                let text = try await selectionReader.readSelectedText(from: sourceApplication)
                guard !Task.isCancelled else { return }
                polishWindowController.show(sourceText: text, on: screen)
            } catch {
                guard !Task.isCancelled else { return }
                let message: String
                if case TranslatorAppError.noSelectedText = error {
                    message = "未读取到选中文字，可在原文区域粘贴内容。"
                } else {
                    message = error.localizedDescription
                }
                polishWindowController.show(sourceText: "", on: screen, captureError: message)
            }
        }
    }

    /// Shows the floating panel without reading selection or calling the model.
    ///
    /// This menu command isolates the UI layer: if it appears, the popover
    /// drawing path is healthy and later failures are in shortcut capture,
    /// selection capture, backend startup, or model calls.
    @objc private func showTestPopover() {
        floatingPanel.showResult("测试弹窗正常。")
    }

    /// Displays how the global shortcut was registered for this app instance.
    ///
    /// Carbon hotkey registration can fail when the same chord is already owned
    /// by macOS or another app. Surfacing the status in-app makes shortcut
    /// failures visible instead of leaving the menu-bar app silently idle.
    @objc private func showHotkeyStatus() {
        let message = hotkeyMonitor?.diagnosticMessage ?? "快捷键监听器尚未创建。"
        floatingPanel.showResult(message)
    }

    @objc private func checkAccessibilityPermission() {
        if AccessibilitySelectionReader.isAccessibilityTrusted(prompt: true) {
            floatingPanel.showResult("辅助功能权限已开启。")
        } else {
            floatingPanel.showError("辅助功能权限尚未开启，授权后请重新启动本工具。")
        }
    }

    @objc private func checkBackendService() {
        Task { @MainActor in
            do {
                floatingPanel.showLoading("正在检查本地翻译服务...")
                try await backendSupervisor.ensureBackendRunning()
                floatingPanel.showResult("本地翻译服务已就绪。")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                floatingPanel.showError(message)
            }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
