import AppKit

@MainActor
final class FloatingPanelController: NSObject, NSTextViewDelegate {
    private static let candidateLinkScheme = "selected-translator-candidate"

    private let panel: NSPanel
    private let containerView = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private var autoHideTimer: Timer?
    private var outsideClickMonitor: Any?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        containerView.material = .popover
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

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
        textView.delegate = self
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.controlAccentColor,
            .underlineStyle: 0
        ]

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        containerView.addSubview(titleLabel)
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
        show(title: "划词翻译", body: message, autoHideAfter: nil, enablesCandidateLinks: false)
    }

    /// Shows the translated text and makes candidate terms directly copyable.
    func showResult(_ translation: String) {
        show(title: "翻译结果", body: translation, autoHideAfter: nil, enablesCandidateLinks: true)
    }

    /// Shows an actionable error from either macOS permission checks or backend calls.
    func showError(_ message: String) {
        show(title: "翻译失败", body: message, autoHideAfter: 8, enablesCandidateLinks: false)
    }

    /// Copies the clicked candidate term and then dismisses the result panel.
    ///
    /// The link payload is generated from the candidate line itself, so only
    /// the term before the optional context parentheses is copied.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url: URL?
        if let swiftURL = link as? URL {
            url = swiftURL
        } else if let nsURL = link as? NSURL {
            url = nsURL as URL
        } else {
            url = nil
        }

        guard
            let url,
            url.scheme == Self.candidateLinkScheme,
            let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "text" })?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !candidate.isEmpty
        else {
            return false
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidate, forType: .string)
        hidePanel()
        return true
    }

    /// Hides the floating result panel when the user clicks the close control.
    @objc private func closePanel() {
        hidePanel()
    }

    private func show(
        title: String,
        body: String,
        autoHideAfter seconds: TimeInterval?,
        enablesCandidateLinks: Bool
    ) {
        autoHideTimer?.invalidate()
        titleLabel.stringValue = title
        renderBody(body, enablesCandidateLinks: enablesCandidateLinks)

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

    /// Renders model text and turns candidate bullet terms into click targets.
    ///
    /// The backend keeps the response as plain text for a stable HTTP contract;
    /// this method is the single UI boundary that adds AppKit-specific link and
    /// background styling for candidate terms.
    private func renderBody(_ body: String, enablesCandidateLinks: Bool) {
        let font = textView.font ?? .systemFont(ofSize: 14)
        let attributedBody = NSMutableAttributedString(
            string: body,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )

        if enablesCandidateLinks {
            for candidate in candidateTokens(in: body) {
                guard let url = candidateLinkURL(for: candidate.text) else {
                    continue
                }

                attributedBody.addAttributes(
                    [
                        .link: url,
                        .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.14),
                        .foregroundColor: NSColor.controlAccentColor
                    ],
                    range: candidate.range
                )
            }
        }

        if let textStorage = textView.textStorage {
            textStorage.setAttributedString(attributedBody)
            return
        }

        textView.string = body
    }

    /// Builds a private URL payload so AppKit can route a clicked candidate back
    /// through `NSTextViewDelegate` without exposing any external URL scheme.
    private func candidateLinkURL(for candidate: String) -> URL? {
        var components = URLComponents()
        components.scheme = Self.candidateLinkScheme
        components.host = "copy"
        components.queryItems = [URLQueryItem(name: "text", value: candidate)]
        return components.url
    }

    /// Finds candidate bullet terms in the backend's plain-text response.
    ///
    /// Only bullet lines after the explicit `候选：` marker are treated as
    /// copyable candidates. This avoids turning ordinary translated lists into
    /// clickable terms when the selected source text itself contains bullets.
    private func candidateTokens(in body: String) -> [(range: NSRange, text: String)] {
        let nsBody = body as NSString
        var tokens: [(range: NSRange, text: String)] = []
        var isInCandidateSection = false

        nsBody.enumerateSubstrings(
            in: NSRange(location: 0, length: nsBody.length),
            options: [.byLines]
        ) { [weak self] line, lineRange, _, _ in
            guard let self, let line else {
                return
            }

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine == "候选：" || trimmedLine == "候选:" {
                isInCandidateSection = true
                return
            }

            guard
                isInCandidateSection,
                let token = self.candidateToken(in: line, lineRange: lineRange)
            else {
                return
            }
            tokens.append(token)
        }

        return tokens
    }

    /// Extracts the clickable term from one candidate line.
    private func candidateToken(in line: String, lineRange: NSRange) -> (range: NSRange, text: String)? {
        let nsLine = line as NSString
        var start = 0

        while start < nsLine.length, isWhitespace(nsLine.character(at: start)) {
            start += 1
        }

        guard start < nsLine.length else {
            return nil
        }

        let marker = nsLine.substring(with: NSRange(location: start, length: 1))
        guard marker == "-" || marker == "•" || marker == "·" else {
            return nil
        }

        start += 1
        while start < nsLine.length, isWhitespace(nsLine.character(at: start)) {
            start += 1
        }

        var end = start
        while end < nsLine.length {
            let character = nsLine.substring(with: NSRange(location: end, length: 1))
            if character == "（" || character == "(" {
                break
            }
            end += 1
        }

        while end > start, isWhitespace(nsLine.character(at: end - 1)) {
            end -= 1
        }

        guard end > start else {
            return nil
        }

        let localRange = NSRange(location: start, length: end - start)
        return (
            NSRange(location: lineRange.location + localRange.location, length: localRange.length),
            nsLine.substring(with: localRange)
        )
    }

    private func isWhitespace(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(Int(codeUnit)) else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
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
        let titleRightInset = buttonSize + buttonGap

        panel.setContentSize(NSSize(width: width, height: height))
        containerView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        titleLabel.frame = NSRect(
            x: padding,
            y: height - padding - titleHeight,
            width: max(contentWidth - titleRightInset, 120),
            height: titleHeight
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
