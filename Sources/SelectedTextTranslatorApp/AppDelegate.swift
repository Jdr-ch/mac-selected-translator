import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let backendClient: BackendClient
    private let backendSupervisor: BackendSupervisor
    private let selectionReader = AccessibilitySelectionReader()
    private let floatingPanel = FloatingPanelController()
    private var hotkeyMonitor: HotkeyMonitor?
    private var statusItem: NSStatusItem?
    private var isTranslating = false

    override init() {
        let configuration = AppConfiguration()
        self.backendClient = BackendClient(configuration: configuration)
        self.backendSupervisor = BackendSupervisor(configuration: configuration)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        promptForAccessibilityIfNeeded()
        warmUpBackend()

        hotkeyMonitor = HotkeyMonitor { [weak self] in
            self?.handleTranslateShortcut()
        }
        hotkeyMonitor?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyMonitor?.stop()
        backendSupervisor.terminateOwnedBackend()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "译"
        item.button?.toolTip = "划词翻译：按 Option+Shift+F"

        let menu = NSMenu()
        menu.addItem(makeMenuItem(title: "翻译当前选中文字", action: #selector(translateFromMenu)))
        menu.addItem(makeMenuItem(title: "检查辅助功能权限", action: #selector(checkAccessibilityPermission)))
        menu.addItem(makeMenuItem(title: "检查/启动本地翻译服务", action: #selector(checkBackendService)))
        menu.addItem(.separator())
        menu.addItem(makeMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
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

    /// Handles the global Option+Shift+F gesture.
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
            let translation = try await backendClient.translate(selectedText, targetLanguage: "中文")
            floatingPanel.showResult(translation)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            floatingPanel.showError(message)
        }
    }

    @objc private func translateFromMenu() {
        handleTranslateShortcut()
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
