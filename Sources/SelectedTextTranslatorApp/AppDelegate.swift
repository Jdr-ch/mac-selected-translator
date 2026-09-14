import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let backendClient: BackendClient
    private let backendSupervisor: BackendSupervisor
    private let modelSelection: ModelSelectionStore
    private let modelWindowController: ModelSelectionWindowController
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
    /// Retained through selection and streaming so dismissal cancels every late UI update.
    private var translationTask: Task<Void, Never>?
    private var hotkeyMonitor: HotkeyMonitor?
    private var statusItem: NSStatusItem?
    /// Updates the standard status-button image so AppKit can reuse it on every display's menu bar.
    private var statusIconAnimator: StatusItemIconAnimator?
    /// 捕获原生按钮的来源应用，并保留独立休眠绿灯命中区域。
    private var statusItemMouseMonitor: Any?
    /// Retained so the status-menu label follows both the menu toggle and the green indicator.
    private var sleepMenuItem: NSMenuItem?
    private var modelMenuItem: NSMenuItem?
    /// 电源模块独立采集与缓存，不参与 A/文动画的逐帧计算。
    private let powerMonitor = PowerMonitor()
    private let powerStatusDisplay = PowerStatusDisplay()
    private var powerPopover: PowerPopoverController?
    private var showMenuBarPower = PowerDisplayPreference.isPowerShown()
    private var powerPresentation = PowerPresentation(snapshot: PowerSnapshot(), showPower: true)
    /// 鼠标按下时先捕获选区来源，避免弹出面板改变前台应用后再读取。
    private var statusSourceCaptured = false
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
        let selection = ModelSelectionStore()
        self.modelSelection = selection
        self.modelWindowController = ModelSelectionWindowController(
            session: ModelSelectionSession(selection: selection) { provider in
                try await supervisor.ensureBackendRunning()
                try Task.checkCancellation()
                return try await client.modelInformation(for: provider)
            }
        )
        self.polishWindowController = ContentPolishWindowController(session: ContentPolishSession { request in
            let provider = selection.provider
            let reasoning = selection.reasoning(for: provider)
            try await supervisor.ensureBackendRunning()
            try Task.checkCancellation()
            return try await client.polish(request, provider: provider, reasoning: reasoning)
        })
        super.init()
        floatingPanel.onDismiss = { [weak self] in self?.translationTask?.cancel() }
        selection.onChange = { [weak self] in self?.updateModelMenu() }
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
        powerMonitor.stop()
        powerPopover?.close()
        if let statusItemMouseMonitor {
            NSEvent.removeMonitor(statusItemMouseMonitor)
        }
        iphoneLocationWindowController.shutdown()
        flowchartWindowController?.shutdown()
        polishSelectionTask?.cancel()
        translationTask?.cancel()
        polishWindowController.session.cancel()
        modelWindowController.session.cancel()
        sleepPreventionController.restoreSystemSleep()
        backendSupervisor.terminateOwnedBackend()
    }

    private func setupStatusItem() {
        let statusBar = NSStatusBar.system
        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.title = ""
            button.imagePosition = .imageRight
            button.imageScaling = .scaleNone
            button.toolTip = "划词翻译：按 Option+Tab"
            button.setAccessibilityLabel("划词翻译")
            button.target = self
            button.action = #selector(toggleStatusPopover)
            setupStatusIcon(in: button, statusBarThickness: statusBar.thickness)
        }

        let menu = NSMenu()
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
        let modelMenuItem = makeMenuItem(title: "", action: #selector(showModelSelection))
        self.modelMenuItem = modelMenuItem
        updateModelMenu()
        menu.addItem(modelMenuItem)
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem = item
        powerPopover = PowerPopoverController(menu: menu, showPower: showMenuBarPower)
        powerPopover?.onVisibilityChange = { [weak self] visible in self?.powerMonitor.setPanelVisible(visible) }
        powerPopover?.onShowPowerChange = { [weak self] showPower in
            guard let self else { return }
            self.showMenuBarPower = showPower
            UserDefaults.standard.set(showPower, forKey: PowerDisplayPreference.defaultsKey)
            // 切换偏好只重用已有读数，避免点击复选框增加硬件读取或重建采样计时器。
            self.updatePowerSnapshot(self.powerMonitor.snapshot)
        }
        powerMonitor.onChange = { [weak self] snapshot in self?.updatePowerSnapshot(snapshot) }
        installStatusItemMouseMonitor()
        updateSleepPreventionUI()
        updatePowerSnapshot(powerMonitor.snapshot)
        powerMonitor.start()
    }

    /// 原生图片承载原有动画，主题变化时单独通知静态电源前缀。
    private func setupStatusIcon(in statusButton: NSStatusBarButton, statusBarThickness: CGFloat) {
        let animator = StatusItemIconAnimator(
            button: statusButton,
            statusBarThickness: statusBarThickness
        )
        animator.onAppearanceChange = { [weak self] in self?.updatePowerStatusButton() }
        animator.start()
        statusIconAnimator = animator
    }

    /// 保留原生按钮事件链，只消费当前图片中的休眠绿灯；新增标题区域一律打开面板。
    private func installStatusItemMouseMonitor() {
        statusItemMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self,
                  let button = self.statusItem?.button,
                  event.window === button.window else {
                return event
            }

            let point = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(point) else { return event }
            if self.powerPopover?.isShown != true {
                self.menuSourceApplication = NSWorkspace.shared.frontmostApplication
                self.statusSourceCaptured = true
            }
            let imageFrame = button.cell?.imageRect(forBounds: button.bounds) ?? .zero
            guard StatusItemVisualStyle.hitTarget(at: point, buttonBounds: button.bounds, imageFrame: imageFrame,
                isPreventingSleep: self.sleepPreventionController.isPreventingSleep) == .sleepIndicator else { return event }
            self.statusSourceCaptured = false
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

    /// 休眠控制器仍是唯一状态来源，同时更新命令标题与原绿灯。
    private func updateSleepPreventionUI() {
        sleepMenuItem?.title = sleepPreventionController.actionTitle
        powerPopover?.refreshCommands()
        updateStatusItemAppearance()
    }

    /// 原绿灯仍由休眠控制器驱动，电源前缀的静态附件单独更新。
    private func updateStatusItemAppearance() {
        guard statusItem?.button != nil else {
            return
        }

        let isPreventingSleep = sleepPreventionController.isPreventingSleep
        statusIconAnimator?.isPreventingSleep = isPreventingSleep
        statusIconAnimator?.isSleepIndicatorBright = sleepPreventionController.isSleepStatusLightBright

        updatePowerStatusButton()
    }

    /// 数值转换只发生在新快照或功率开关切换时，菜单栏与左栏共享同一份显示结果。
    private func updatePowerSnapshot(_ snapshot: PowerSnapshot) {
        powerPresentation = PowerPresentation(snapshot: snapshot, showPower: showMenuBarPower)
        updatePowerStatusButton()
        powerPopover?.update(snapshot: snapshot, presentation: powerPresentation)
    }

    /// 标题附件变化才重绘；主题改变时独立失效缓存，不扩大原动态图像的尺寸。
    private func updatePowerStatusButton() {
        guard let button = statusItem?.button else { return }
        powerStatusDisplay.update(powerPresentation, button: button)
        var description = "划词翻译；\(powerPresentation.state.title)，\(powerPresentation.percent)"
        if let power = powerPresentation.menuPowerDescription { description += "；\(power)" }
        if sleepPreventionController.isPreventingSleep { description += "；禁止休眠中" }
        button.toolTip = description + "；按 Option+Tab"
        button.setAccessibilityLabel(description)
    }

    /// 原生按钮的 target-action 打开同一面板，辅助功能触发时也先记录来源应用。
    @objc private func toggleStatusPopover() {
        guard let button = statusItem?.button else { return }
        if powerPopover?.isShown != true, !statusSourceCaptured {
            menuSourceApplication = NSWorkspace.shared.frontmostApplication
        }
        statusSourceCaptured = false
        powerPopover?.toggle(relativeTo: button)
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
    /// Only the HTTP service is warmed up; model configuration is read when a request starts.
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

    /// 快捷键捕获当前应用，菜单使用展开前的来源；串行翻译避免重复请求与浮层竞态。
    private func handleTranslateShortcut(sourceApplication: NSRunningApplication? = nil) {
        guard translationTask == nil else { return }
        let source = sourceApplication ?? NSWorkspace.shared.frontmostApplication
        translationTask = Task { @MainActor in
            await translateCurrentSelection(from: source)
            translationTask = nil
        }
    }

    /// 从已捕获应用读取选区，保持原有服务调用与鼠标附近的分阶段状态反馈。
    private func translateCurrentSelection(from sourceApplication: NSRunningApplication?) async {
        let provider = modelSelection.provider
        let reasoning = modelSelection.reasoning(for: provider)
        isTranslating = true
        floatingPanel.showLoading("正在读取选中文字...")
        defer {
            isTranslating = false
        }

        do {
            floatingPanel.showLoading("正在检查本地翻译服务...")
            try await backendSupervisor.ensureBackendRunning()
            try Task.checkCancellation()
            let selectedText = try await selectionReader.readSelectedText(from: sourceApplication)
            try Task.checkCancellation()
            floatingPanel.showLoading("正在翻译...")
            let result = try await backendClient.translate(selectedText, targetLanguage: "auto",
                                                           provider: provider, reasoning: reasoning) { [weak self] preview in
                guard !Task.isCancelled else { return }
                self?.floatingPanel.showStreamingResult(preview)
            }
            try Task.checkCancellation()
            floatingPanel.showResult(result.text, sourceText: selectedText, completion: result.completion, followsMouse: false)
        } catch {
            if Task.isCancelled { return }
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            floatingPanel.showError(message)
        }
    }

    @objc private func translateFromMenu() {
        handleTranslateShortcut(sourceApplication: menuSourceApplication)
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

    /// Opens a retained editor instead of starting another app or replacing translation state.
    @objc private func showFlowchart() {
        if flowchartWindowController == nil {
            flowchartWindowController = FlowchartWindowController(defaultProvider: { [modelSelection] in
                modelSelection.provider
            }, reasoningForProvider: { [modelSelection] provider in
                modelSelection.reasoning(for: provider)
            }) { [weak self] in
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

    private func updateModelMenu() {
        modelMenuItem?.title = "模型切换：\(modelSelection.provider.title)..."
        powerPopover?.refreshCommands()
    }

    @objc private func showModelSelection() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        modelWindowController.show(on: screen)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
