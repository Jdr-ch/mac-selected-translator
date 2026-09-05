import AppKit

/// Keeps candidate rows compact while allowing wrapped context copy to grow naturally.
enum CandidateRowLayout {
    static let minimumHeight: CGFloat = 30
    static let verticalInset: CGFloat = 3

    /// Adds balanced vertical padding around the measured candidate text.
    static func preferredHeight(textHeight: CGFloat) -> CGFloat {
        max(minimumHeight, ceil(textHeight) + verticalInset * 2)
    }
}

@MainActor
final class FloatingPanelController: NSObject {
    private enum Metrics {
        static let panelWidth: CGFloat = 420
        static let maximumPanelHeight: CGFloat = 360
        static let headerHeight: CGFloat = 50
        static let contentPadding: CGFloat = 18
        static let contentWidth = panelWidth - contentPadding * 2
    }

    private enum PopupState {
        case loading(message: String)
        case result(TranslationResultPresentation)
        case error(message: String)
    }

    private let panel: NSPanel
    private let containerView = NSVisualEffectView()
    private let headerIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let headerSeparator = NSBox()
    private let scrollView = NSScrollView()
    private let bodyView = FlippedView()
    private var progressIndicator: NSProgressIndicator?
    private var autoHideTimer: Timer?
    private var outsideClickMonitor: Any?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 160),
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
        panel.animationBehavior = .utilityWindow

        containerView.material = .popover
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.masksToBounds = true

        headerIconView.image = NSImage(
            systemSymbolName: "translate",
            accessibilityDescription: "划词翻译"
        )
        headerIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        headerIconView.contentTintColor = .controlAccentColor
        headerIconView.imageScaling = .scaleProportionallyDown

        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        configureIconButton(
            closeButton,
            systemSymbolName: "xmark",
            accessibilityLabel: "关闭",
            action: #selector(closePanel)
        )

        headerSeparator.boxType = .separator

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = bodyView

        containerView.addSubview(headerIconView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(closeButton)
        containerView.addSubview(headerSeparator)
        containerView.addSubview(scrollView)
        panel.contentView = containerView
        startOutsideClickMonitor()
    }

    /// Shows progress until the current selection or backend request advances to a terminal state.
    func showLoading(_ message: String) {
        show(title: "划词翻译", state: .loading(message: message), autoHideAfter: nil)
    }

    /// Shows the translated sections and exposes every candidate row as a copy action.
    func showResult(_ translation: String) {
        show(
            title: "翻译结果",
            state: .result(TranslationResultPresentation(response: translation)),
            autoHideAfter: nil
        )
    }

    /// Shows the actionable failure reason briefly before dismissing the transient panel.
    func showError(_ message: String) {
        show(title: "翻译失败", state: .error(message: message), autoHideAfter: 8)
    }

    /// Rebuilds only the state body while keeping the header and scroll boundary stable.
    private func show(title: String, state: PopupState, autoHideAfter seconds: TimeInterval?) {
        autoHideTimer?.invalidate()
        progressIndicator?.stopAnimation(nil)
        progressIndicator = nil
        bodyView.subviews.forEach { $0.removeFromSuperview() }
        titleLabel.stringValue = title

        let bodyHeight: CGFloat
        switch state {
        case let .loading(message):
            bodyHeight = renderLoading(message)
        case let .result(presentation):
            bodyHeight = renderResult(presentation)
        case let .error(message):
            bodyHeight = renderError(message)
        }

        let height = min(max(Metrics.headerHeight + bodyHeight, 140), Metrics.maximumPanelHeight)
        layoutPanel(height: height, bodyHeight: bodyHeight)
        positionNearMouse(width: Metrics.panelWidth, height: height)
        panel.orderFrontRegardless()

        if let seconds {
            autoHideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.hidePanel()
                }
            }
        }
    }

    /// Builds the spinner, status copy, and skeleton lines used during every asynchronous translation phase.
    private func renderLoading(_ message: String) -> CGFloat {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: Metrics.contentPadding, y: 20, width: 20, height: 20)
        spinner.startAnimation(nil)
        bodyView.addSubview(spinner)
        progressIndicator = spinner

        let heading = makeLabel("正在翻译", font: .systemFont(ofSize: 14, weight: .medium))
        heading.frame = NSRect(x: 50, y: 18, width: 352, height: 18)
        bodyView.addSubview(heading)

        let detail = makeLabel(message, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        detail.frame = NSRect(x: 50, y: 42, width: 352, height: 18)
        bodyView.addSubview(detail)

        let skeleton = PopupSkeletonView()
        skeleton.frame = NSRect(x: Metrics.contentPadding, y: 80, width: Metrics.contentWidth, height: 51)
        bodyView.addSubview(skeleton)
        return 150
    }

    /// Lays out primary text, pronunciation, and copyable candidates from the parsed backend response.
    private func renderResult(_ presentation: TranslationResultPresentation) -> CGFloat {
        var y = Metrics.contentPadding

        let sectionLabel = makeLabel(
            "主译",
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
        sectionLabel.frame = NSRect(x: Metrics.contentPadding, y: y, width: Metrics.contentWidth, height: 15)
        bodyView.addSubview(sectionLabel)
        y += 23

        let primaryText = presentation.primaryTranslation.isEmpty ? "暂无翻译结果" : presentation.primaryTranslation
        let primary = makeLabel(primaryText, font: .systemFont(ofSize: 22, weight: .medium))
        let primaryHeight = measuredTextHeight(primary.attributedStringValue, width: Metrics.contentWidth)
        primary.frame = NSRect(
            x: Metrics.contentPadding,
            y: y,
            width: Metrics.contentWidth,
            height: max(primaryHeight, 31)
        )
        bodyView.addSubview(primary)
        y += max(primaryHeight, 31)

        if let pronunciation = presentation.pronunciation {
            y += 12
            let pronunciationBackground = PopupTintedBackgroundView()
            let pronunciationLabel = makePronunciationLabel(pronunciation)
            let pronunciationHeight = max(
                measuredTextHeight(pronunciationLabel.attributedStringValue, width: Metrics.contentWidth - 24) + 18,
                38
            )
            pronunciationBackground.frame = NSRect(
                x: Metrics.contentPadding,
                y: y,
                width: Metrics.contentWidth,
                height: pronunciationHeight
            )
            pronunciationLabel.frame = NSRect(
                x: 12,
                y: 9,
                width: Metrics.contentWidth - 24,
                height: pronunciationHeight - 18
            )
            pronunciationBackground.addSubview(pronunciationLabel)
            bodyView.addSubview(pronunciationBackground)
            y += pronunciationHeight
        }

        if !presentation.candidates.isEmpty {
            y += 18
            let candidatesLabel = makeLabel(
                "候选",
                font: .systemFont(ofSize: 12, weight: .medium),
                color: .secondaryLabelColor
            )
            candidatesLabel.frame = NSRect(
                x: Metrics.contentPadding,
                y: y,
                width: Metrics.contentWidth,
                height: 15
            )
            bodyView.addSubview(candidatesLabel)
            y += 22

            for candidate in presentation.candidates {
                guard let linkURL = TranslationCandidateLink.url(for: candidate.term) else {
                    continue
                }

                let row = CandidateRowButton(candidate: candidate, linkURL: linkURL)
                let rowHeight = row.preferredHeight(for: Metrics.contentWidth)
                row.frame = NSRect(
                    x: Metrics.contentPadding,
                    y: y,
                    width: Metrics.contentWidth,
                    height: rowHeight
                )
                row.target = self
                row.action = #selector(copyCandidate(_:))
                bodyView.addSubview(row)
                y += rowHeight
            }
        }

        return y + Metrics.contentPadding
    }

    /// Builds the warning state with semantic system colors so it follows macOS appearance changes.
    private func renderError(_ message: String) -> CGFloat {
        let icon = NSImageView()
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.circle.fill",
            accessibilityDescription: "翻译失败"
        )
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        icon.contentTintColor = .systemRed
        icon.imageScaling = .scaleProportionallyDown
        icon.frame = NSRect(x: Metrics.contentPadding, y: 39, width: 20, height: 20)
        bodyView.addSubview(icon)

        let heading = makeLabel("未能完成翻译", font: .systemFont(ofSize: 14, weight: .medium))
        heading.frame = NSRect(x: 51, y: 36, width: 351, height: 18)
        bodyView.addSubview(heading)

        let detail = makeLabel(message, font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        let detailHeight = measuredTextHeight(detail.attributedStringValue, width: 351)
        detail.frame = NSRect(x: 51, y: 60, width: 351, height: max(detailHeight, 18))
        bodyView.addSubview(detail)
        return max(112, 78 + detailHeight)
    }

    /// Copies the candidate carried by the existing private-link protocol and dismisses the panel.
    @objc private func copyCandidate(_ sender: CandidateRowButton) {
        guard let candidate = TranslationCandidateLink.candidate(from: sender.linkURL) else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(candidate, forType: .string)
        hidePanel()
    }

    /// Hides the floating result panel when the user clicks the close control.
    @objc private func closePanel() {
        hidePanel()
    }

    /// Creates a wrapping label with semantic defaults shared by all popup states.
    private func makeLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        return label
    }

    /// Styles the optional source word separately from the slash-delimited phonetic spelling.
    private func makePronunciationLabel(
        _ pronunciation: TranslationResultPresentation.Pronunciation
    ) -> NSTextField {
        let attributed = NSMutableAttributedString()
        if let word = pronunciation.word {
            attributed.append(NSAttributedString(
                string: word + "   ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13),
                    .foregroundColor: NSColor.labelColor
                ]
            ))
        }
        attributed.append(NSAttributedString(
            string: pronunciation.phonetic,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.controlAccentColor
            ]
        ))

        let label = NSTextField(labelWithAttributedString: attributed)
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        return label
    }

    /// Measures attributed content against the fixed popup width to keep long text inside the scroll region.
    private func measuredTextHeight(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let rect = text.boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }

    /// Keeps the header fixed while the state body grows up to the approved 360-point limit.
    private func layoutPanel(height: CGFloat, bodyHeight: CGFloat) {
        let bodyViewportHeight = height - Metrics.headerHeight
        let headerBottom = height - Metrics.headerHeight
        let documentHeight = max(bodyHeight, bodyViewportHeight)

        panel.setContentSize(NSSize(width: Metrics.panelWidth, height: height))
        containerView.frame = NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: height)
        headerIconView.frame = NSRect(x: 16, y: headerBottom + 16, width: 18, height: 18)
        titleLabel.frame = NSRect(x: 43, y: headerBottom + 15, width: 325, height: 20)
        closeButton.frame = NSRect(x: 378, y: headerBottom + 11, width: 28, height: 28)
        headerSeparator.frame = NSRect(x: 0, y: headerBottom, width: Metrics.panelWidth, height: 1)
        scrollView.frame = NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: bodyViewportHeight)
        bodyView.frame = NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: documentHeight)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Positions the panel beside the pointer while keeping every edge inside the active screen.
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

    /// Centralizes dismissal so timers, buttons, and outside clicks clear the same transient state.
    private func hidePanel() {
        autoHideTimer?.invalidate()
        progressIndicator?.stopAnimation(nil)
        panel.orderOut(nil)
    }

    /// Applies the shared symbol-only treatment used by the fixed header control.
    private func configureIconButton(
        _ button: NSButton,
        systemSymbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.image = NSImage(
            systemSymbolName: systemSymbolName,
            accessibilityDescription: accessibilityLabel
        )
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.toolTip = accessibilityLabel
        button.target = self
        button.action = action
        button.contentTintColor = .secondaryLabelColor
    }

    /// Watches global mouse clicks so the floating panel behaves like a transient popover.
    private func startOutsideClickMonitor() {
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hideIfClickOutside(NSEvent.mouseLocation)
            }
        }
    }

    /// Dismisses only clicks outside the visible panel, preserving candidate-row interaction.
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

/// Uses top-origin coordinates so dynamically sized result content begins below the fixed header.
@MainActor
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Draws the semantic accent wash behind pronunciation content in both system appearances.
@MainActor
private final class PopupTintedBackgroundView: NSView {
    /// Resolves the accent color at draw time so the wash follows the active macOS appearance.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlAccentColor.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
}

/// Draws the three quiet placeholder lines paired with the indeterminate progress indicator.
@MainActor
private final class PopupSkeletonView: NSView {
    override var isFlipped: Bool { true }

    /// Keeps the longest placeholder on top to mirror the approved loading-state hierarchy.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.65).setFill()

        let widths: [CGFloat] = [1, 0.82, 0.58]
        for (index, fraction) in widths.enumerated() {
            let rect = NSRect(
                x: 0,
                y: CGFloat(index) * 21,
                width: bounds.width * fraction,
                height: 9
            )
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }
}

/// Presents one full-width candidate as a single copy target with context and a familiar copy symbol.
@MainActor
private final class CandidateRowButton: NSButton {
    let linkURL: URL

    private let candidateLabel = NSTextField(labelWithString: "")
    private let copyIconView = NSImageView()
    private let separator = NSBox()
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false {
        didSet {
            updateHoverAppearance()
        }
    }

    /// Builds display text separately from the link payload so explanatory context is never copied.
    init(candidate: TranslationResultPresentation.Candidate, linkURL: URL) {
        self.linkURL = linkURL
        super.init(frame: .zero)

        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 5
        toolTip = "复制“\(candidate.term)”"
        setAccessibilityLabel("复制候选翻译：\(candidate.term)")

        candidateLabel.attributedStringValue = Self.makeTitle(candidate)
        candidateLabel.maximumNumberOfLines = 0
        candidateLabel.lineBreakMode = .byWordWrapping
        candidateLabel.cell?.wraps = true

        copyIconView.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "复制")
        copyIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        copyIconView.contentTintColor = .tertiaryLabelColor
        copyIconView.imageScaling = .scaleProportionallyDown

        separator.boxType = .separator
        addSubview(separator)
        addSubview(candidateLabel)
        addSubview(copyIconView)
    }

    /// Candidate rows are created from parsed runtime responses, not Interface Builder archives.
    required init?(coder: NSCoder) {
        nil
    }

    /// Returns a stable minimum row height and grows only when explanatory copy wraps.
    func preferredHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(width - 38, 80)
        let textHeight = candidateLabel.attributedStringValue.boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        return CandidateRowLayout.preferredHeight(textHeight: textHeight)
    }

    /// Reflows the candidate copy and trailing icon without changing the row's external size.
    override func layout() {
        super.layout()
        separator.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        candidateLabel.frame = NSRect(
            x: 4,
            y: CandidateRowLayout.verticalInset,
            width: max(bounds.width - 38, 0),
            height: bounds.height - CandidateRowLayout.verticalInset * 2
        )
        copyIconView.frame = NSRect(x: bounds.width - 22, y: (bounds.height - 16) / 2, width: 16, height: 16)
    }

    /// Replaces the tracking region after resizing so the full row retains hover feedback.
    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    /// Highlights the row only while the pointer is inside its copy target.
    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    /// Restores neutral colors as soon as the pointer leaves the candidate row.
    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    /// Re-resolves semantic hover colors when macOS switches between light and dark appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHoverAppearance()
    }

    /// Ensures labels and icons remain part of the row's single, full-width click target.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else {
            return nil
        }
        return self
    }

    /// Applies a restrained accent hover without changing the row's fixed dimensions.
    private func updateHoverAppearance() {
        layer?.backgroundColor = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
        copyIconView.contentTintColor = isHovered ? .controlAccentColor : .tertiaryLabelColor
    }

    /// Combines the copyable term and optional context using the approved visual hierarchy.
    private static func makeTitle(_ candidate: TranslationResultPresentation.Candidate) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: candidate.term,
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if let context = candidate.context {
            attributed.append(NSAttributedString(
                string: "   \(context)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            ))
        }
        return attributed
    }
}
