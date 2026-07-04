import AppKit

@MainActor
final class FloatingPanelController {
    private let panel: NSPanel
    private let containerView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()
    private let closeButton = NSButton()
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var autoHideTimer: Timer?
    private var outsideClickMonitor: Any?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true

        containerView.material = .popover
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        configureIconButton(
            copyButton,
            systemSymbolName: "doc.on.doc",
            accessibilityLabel: "复制",
            action: #selector(copyCurrentTranslation)
        )
        configureIconButton(
            closeButton,
            systemSymbolName: "xmark.circle.fill",
            accessibilityLabel: "关闭",
            action: #selector(closePanel)
        )

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        containerView.addSubview(titleLabel)
        containerView.addSubview(copyButton)
        containerView.addSubview(closeButton)
        containerView.addSubview(scrollView)
        panel.contentView = containerView
        startOutsideClickMonitor()
    }

    /// Shows a short loading message near the current pointer.
    ///
    /// Loading states intentionally stay visible until a result or error
    /// replaces them, because hiding the panel while the model is still working
    /// makes the shortcut feel unreliable.
    func showLoading(_ message: String) {
        show(title: "划词翻译", body: message, autoHideAfter: nil, showsCopyButton: false)
    }

    /// Shows the translated text and keeps it selectable for copy/paste.
    func showResult(_ translation: String) {
        show(title: "翻译结果", body: translation, autoHideAfter: nil, showsCopyButton: true)
    }

    /// Shows an actionable error from either macOS permission checks or backend calls.
    func showError(_ message: String) {
        show(title: "翻译失败", body: message, autoHideAfter: 8, showsCopyButton: false)
    }

    /// Copies the currently displayed translation to the system pasteboard.
    ///
    /// This action is only exposed for successful translation results, so it
    /// copies the text the user is looking at instead of the original selected
    /// source text or transient loading/error messages.
    @objc private func copyCurrentTranslation() {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Hides the floating result panel when the user clicks the close control.
    @objc private func closePanel() {
        hidePanel()
    }

    private func show(
        title: String,
        body: String,
        autoHideAfter seconds: TimeInterval?,
        showsCopyButton: Bool
    ) {
        autoHideTimer?.invalidate()
        titleLabel.stringValue = title
        textView.string = body
        copyButton.isHidden = !showsCopyButton

        let width: CGFloat = 420
        let horizontalPadding: CGFloat = 18
        let bodyWidth = width - horizontalPadding * 2
        let bodyHeight = measuredHeight(for: body, width: bodyWidth)
        let height = min(max(bodyHeight + 66, 104), 360)

        layoutPanel(width: width, height: height, bodyHeight: bodyHeight)
        positionNearMouse(width: width, height: height)
        panel.orderFrontRegardless()

        if let seconds {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.panel.orderOut(nil)
                }
            }
        }
    }

    private func layoutPanel(width: CGFloat, height: CGFloat, bodyHeight: CGFloat) {
        let padding: CGFloat = 18
        let titleHeight: CGFloat = 20
        let buttonSize: CGFloat = 24
        let buttonGap: CGFloat = 6
        let gap: CGFloat = 10
        let scrollHeight = height - padding * 2 - titleHeight - gap
        let contentWidth = width - padding * 2
        let closeX = width - padding - buttonSize
        let copyX = closeX - buttonGap - buttonSize
        let titleRightInset = copyButton.isHidden ? buttonSize + buttonGap : buttonSize * 2 + buttonGap * 2

        panel.setContentSize(NSSize(width: width, height: height))
        containerView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        titleLabel.frame = NSRect(
            x: padding,
            y: height - padding - titleHeight,
            width: max(contentWidth - titleRightInset, 120),
            height: titleHeight
        )
        copyButton.frame = NSRect(
            x: copyX,
            y: height - padding - buttonSize + 2,
            width: buttonSize,
            height: buttonSize
        )
        closeButton.frame = NSRect(
            x: closeX,
            y: height - padding - buttonSize + 2,
            width: buttonSize,
            height: buttonSize
        )
        scrollView.frame = NSRect(
            x: padding,
            y: padding,
            width: contentWidth,
            height: scrollHeight
        )

        let documentHeight = max(bodyHeight + 8, scrollHeight)
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: documentHeight)
        textView.textContainer?.containerSize = NSSize(
            width: contentWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
    }

    private func measuredHeight(for text: String, width: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14)
        let rect = NSString(string: text).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    private func positionNearMouse(width: CGFloat, height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let margin: CGFloat = 10

        var x = mouse.x + 14
        var y = mouse.y - height - 14

        if x + width > visibleFrame.maxX - margin {
            x = visibleFrame.maxX - width - margin
        }
        if y < visibleFrame.minY + margin {
            y = mouse.y + 14
        }
        if y + height > visibleFrame.maxY - margin {
            y = visibleFrame.maxY - height - margin
        }

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Centralizes panel dismissal so timers, close button, and outside clicks
    /// all clear the same UI state before hiding the floating window.
    private func hidePanel() {
        autoHideTimer?.invalidate()
        panel.orderOut(nil)
    }

    private func configureIconButton(
        _ button: NSButton,
        systemSymbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        let image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: accessibilityLabel
        )

        button.image = image
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = accessibilityLabel
        button.target = self
        button.action = action
        button.contentTintColor = .secondaryLabelColor
    }

    /// Watches global mouse clicks so the floating panel behaves like a popover.
    ///
    /// Clicking outside the panel means the user has moved focus back to the
    /// underlying app, so the translation result is dismissed automatically.
    private func startOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfClickOutside(NSEvent.mouseLocation)
            }
        }
    }

    /// Dismisses the panel only when the click lands outside its screen frame.
    private func hideIfClickOutside(_ eventLocation: NSPoint) {
        guard panel.isVisible, !panel.frame.contains(eventLocation) else {
            return
        }

        hidePanel()
    }

    deinit {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
    }
}
