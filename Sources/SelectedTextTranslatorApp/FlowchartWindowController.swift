import AppKit
import UniformTypeIdentifiers

/// Retained menu tool with native editing controls and one local SVG rendering surface.
@MainActor
final class FlowchartWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    let session: FlowchartSession
    let preview = FlowchartPreview()
    private let inputView = NSTextView()
    private let modelBox = NSPopUpButton()
    private let titleField = NSTextField(string: "")
    private let subtitleField = NSTextField(string: "")
    private let stepsStack = FlowchartStepListView()
    private let generateButton = NSButton(title: "生成", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let styleControl = NSSegmentedControl()
    private let formatControl = NSPopUpButton()
    private let resolutionControl = NSSegmentedControl()
    private let zoomControl = NSPopUpButton()
    private let exportButton = NSButton(title: "导出", target: nil, action: nil)
    private let copyButton = NSButton(title: "", target: nil, action: nil)
    private let revealExportButton = NSButton(title: "在 Finder 中显示", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var stepRows: [FlowchartStepEditor] = []
    private var renderedDocument: FlowchartDocument?
    private var renderedStyle: FlowchartStyle?
    private var renderTask: Task<Void, Never>?
    // Export owns an immutable document snapshot; controls are disabled until the file/copy completes.
    private var isExporting = false
    private var previewReady = false
    private var didPositionWindow = false
    // Retain the last successfully written file so reopening the window can still reveal its location.
    private(set) var lastExportURL: URL?
    private let revealExport: (URL) -> Void

    init(configuration: AppConfiguration = AppConfiguration(), defaults: UserDefaults = .standard,
         defaultProvider: @escaping () -> ModelProvider = { .qwen },
         revealExport: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
         ensureBackend: @escaping () async throws -> Void) {
        let client = FlowchartClient(configuration: configuration)
        self.revealExport = revealExport
        session = FlowchartSession(defaults: defaults, defaultProvider: defaultProvider) { text, provider in
            try await ensureBackend()
            try Task.checkCancellation()
            return try await client.generate(text: text, provider: provider)
        }
        let window = FlowchartWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "生成流程图"
        window.contentMinSize = NSSize(width: 900, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureControls()
        layoutControls()
        session.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Reopening preserves the same document, render process, and user-adjusted window dimensions.
    func showWindow() {
        session.beginPresentation()
        if !didPositionWindow, let window {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            if let screen {
                let visible = screen.visibleFrame.insetBy(dx: 20, dy: 20)
                let width = min(window.frame.width, visible.width)
                let height = min(window.frame.height, visible.height)
                window.minSize = NSSize(width: min(900, width), height: min(642, height))
                window.setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                                       width: width, height: height), display: false)
            }
            didPositionWindow = true
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { session.endPresentation() }

    /// App shutdown cancels this feature's waiting tasks without touching other tools or services.
    func shutdown() {
        session.endPresentation()
        renderTask?.cancel()
    }

    private func configureControls() {
        inputView.font = .systemFont(ofSize: 13)
        inputView.isRichText = false
        inputView.allowsUndo = true
        inputView.isAutomaticQuoteSubstitutionEnabled = false
        inputView.isAutomaticDashSubstitutionEnabled = false
        inputView.textContainerInset = NSSize(width: 8, height: 8)
        inputView.isVerticallyResizable = true
        inputView.isHorizontallyResizable = false
        inputView.autoresizingMask = [.width]
        inputView.textContainer?.widthTracksTextView = true
        inputView.delegate = self
        modelBox.addItems(withTitles: ModelProvider.allCases.map(\.title))
        modelBox.target = self
        modelBox.action = #selector(modelChanged)
        modelBox.setAccessibilityLabel("流程图模型")
        titleField.placeholderString = "输入图表标题"
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitleField.placeholderString = "可选"
        subtitleField.font = .systemFont(ofSize: 12)
        titleField.delegate = self
        subtitleField.delegate = self
        styleControl.segmentCount = FlowchartStyle.allCases.count
        for (index, style) in FlowchartStyle.allCases.enumerated() {
            styleControl.setLabel(style.title, forSegment: index)
        }
        styleControl.target = self
        styleControl.action = #selector(styleChanged)
        formatControl.addItems(withTitles: ["PNG", "SVG"])
        formatControl.target = self
        formatControl.action = #selector(formatChanged)
        resolutionControl.segmentCount = 2
        resolutionControl.setLabel("1×", forSegment: 0)
        resolutionControl.setLabel("2×", forSegment: 1)
        resolutionControl.selectedSegment = 0
        resolutionControl.toolTip = "PNG 导出清晰度"
        zoomControl.addItems(withTitles: ["适应窗口", "50%", "100%", "200%"])
        zoomControl.target = self
        zoomControl.action = #selector(zoomChanged)
        for (button, symbol, tooltip, action) in [
            (generateButton, "sparkles", "生成流程图", #selector(generate)),
            (cancelButton, "xmark", "取消生成", #selector(cancel)),
            (addButton, "plus", "添加步骤", #selector(addStep)),
            (exportButton, "square.and.arrow.down", "导出文件", #selector(exportFile)),
            (copyButton, "doc.on.doc", "复制图片", #selector(copyImage)),
            (revealExportButton, "folder", "在 Finder 中显示导出文件", #selector(showExportInFinder))
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
            button.bezelStyle = .rounded
            button.toolTip = tooltip
            button.target = self
            button.action = action
        }
        generateButton.keyEquivalent = "\r"
        generateButton.keyEquivalentModifierMask = [.command]
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        revealExportButton.controlSize = .small
        revealExportButton.font = .systemFont(ofSize: 11)
        revealExportButton.isHidden = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
    }

    /// Fixed control bands surround independently scrolling input, steps, and preview surfaces.
    private func layoutControls() {
        guard let content = window?.contentView else { return }
        let inputScroll = NSScrollView()
        inputScroll.hasVerticalScroller = true
        inputScroll.borderType = .bezelBorder
        inputScroll.documentView = inputView
        let modelRow = NSStackView(views: [NSTextField(labelWithString: "模型"), modelBox])
        modelRow.spacing = 8
        modelBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [NSView(), cancelButton, generateButton])
        actions.spacing = 8
        let metadata = NSStackView()
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 8
        for (name, field) in [("图表标题", titleField), ("副标题", subtitleField)] {
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [label, field])
            row.spacing = 8
            metadata.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: metadata.widthAnchor).isActive = true
        }
        let stepLabel = NSTextField(labelWithString: "步骤")
        stepLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let heading = NSStackView(views: [stepLabel, NSView(), addButton])
        heading.spacing = 8
        stepsStack.orientation = .vertical
        stepsStack.alignment = .leading
        stepsStack.spacing = 16
        stepsStack.translatesAutoresizingMaskIntoConstraints = false
        stepsStack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 14, right: 8)
        let stepsScroll = NSScrollView()
        stepsScroll.hasVerticalScroller = true
        stepsScroll.autohidesScrollers = true
        stepsScroll.documentView = stepsStack
        let editor = NSStackView(views: [NSTextField(labelWithString: "流程描述"), inputScroll, modelRow,
                                        actions, metadata, heading, stepsScroll])
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 10
        editor.translatesAutoresizingMaskIntoConstraints = false
        // Two short rows keep the toolbar usable at the supported minimum window width.
        let viewTools = NSStackView(views: [styleControl, NSView(), zoomControl])
        viewTools.spacing = 8
        let exportTools = NSStackView(views: [NSView(), formatControl, resolutionControl, exportButton, copyButton])
        exportTools.spacing = 8
        let toolbar = NSStackView(views: [viewTools, exportTools])
        toolbar.orientation = .vertical
        toolbar.alignment = .leading
        toolbar.spacing = 6
        let result = NSStackView(views: [toolbar, preview.webView])
        result.orientation = .vertical
        result.alignment = .leading
        result.spacing = 12
        result.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        let status = NSStackView(views: [progress, statusLabel, revealExportButton])
        status.orientation = .horizontal
        status.spacing = 8
        status.translatesAutoresizingMaskIntoConstraints = false
        [editor, divider, result, status].forEach { content.addSubview($0) }
        for view in [inputScroll, modelRow, actions, metadata, heading, stepsScroll] {
            view.widthAnchor.constraint(equalTo: editor.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            editor.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            editor.widthAnchor.constraint(equalToConstant: 320),
            editor.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            inputScroll.heightAnchor.constraint(equalToConstant: 112),
            stepsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            stepsStack.leadingAnchor.constraint(equalTo: stepsScroll.contentView.leadingAnchor),
            stepsStack.topAnchor.constraint(equalTo: stepsScroll.contentView.topAnchor),
            stepsStack.widthAnchor.constraint(equalTo: stepsScroll.contentView.widthAnchor),
            divider.leadingAnchor.constraint(equalTo: editor.trailingAnchor, constant: 16),
            divider.topAnchor.constraint(equalTo: content.topAnchor),
            divider.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            divider.widthAnchor.constraint(equalToConstant: 1),
            result.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 16),
            result.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            result.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            result.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            toolbar.widthAnchor.constraint(equalTo: result.widthAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 62),
            viewTools.widthAnchor.constraint(equalTo: toolbar.widthAnchor),
            exportTools.widthAnchor.constraint(equalTo: toolbar.widthAnchor),
            preview.webView.widthAnchor.constraint(equalTo: result.widthAnchor),
            preview.webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            status.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func refresh() {
        let state = session.state
        if inputView.string != state.input { inputView.string = state.input }
        if titleField.stringValue != state.document.title { titleField.stringValue = state.document.title }
        if subtitleField.stringValue != state.document.subtitle { subtitleField.stringValue = state.document.subtitle }
        modelBox.selectItem(at: ModelProvider.allCases.firstIndex(of: session.provider) ?? 0)
        styleControl.selectedSegment = FlowchartStyle.allCases.firstIndex(of: state.style) ?? 0
        refreshRows()
        updateEnabledState()
        statusLabel.stringValue = session.status
        statusLabel.toolTip = session.status
        statusLabel.textColor = session.hasError ? .systemRed : .secondaryLabelColor
        if renderedDocument != state.document || renderedStyle != state.style { scheduleRender() }
    }

    private func refreshRows() {
        let steps = session.state.document.steps
        if stepRows.map(\.stepID) != steps.map(\.id) {
            stepRows.forEach { stepsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            stepRows = steps.map { step in
                let row = FlowchartStepEditor(step: step)
                row.onEdit = { [weak self] id, title, description in
                    self?.session.edit { state in
                        guard let index = state.document.steps.firstIndex(where: { $0.id == id }) else { return }
                        state.document.steps[index].title = title
                        state.document.steps[index].description = description
                    }
                }
                row.onMove = { [weak self] id, offset in self?.session.moveStep(id: id, offset: offset) }
                row.onDelete = { [weak self] id in
                    self?.session.edit { $0.document.steps.removeAll { $0.id == id } }
                }
                stepsStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stepsStack.widthAnchor, constant: -8).isActive = true
                return row
            }
        }
        for (index, row) in stepRows.enumerated() {
            row.update(step: steps[index], index: index, count: steps.count,
                       enabled: !session.isGenerating && !isExporting)
        }
    }

    private func updateEnabledState() {
        let editing = !session.isGenerating && !isExporting
        inputView.isEditable = editing
        modelBox.isEnabled = editing
        titleField.isEnabled = editing
        subtitleField.isEnabled = editing
        generateButton.isEnabled = editing
        cancelButton.isEnabled = session.isGenerating
        addButton.isEnabled = editing
        styleControl.isEnabled = !isExporting
        formatControl.isEnabled = !isExporting
        resolutionControl.isEnabled = !isExporting && formatControl.indexOfSelectedItem == 0
        exportButton.isEnabled = previewReady && editing
        copyButton.isEnabled = previewReady && editing
        revealExportButton.isHidden = lastExportURL == nil
        revealExportButton.isEnabled = !isExporting
        revealExportButton.toolTip = lastExportURL?.path
        if session.isGenerating || isExporting { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    /// Coalesce keystrokes; changed content replaces the SVG without reloading WebKit or calling AI.
    private func scheduleRender() {
        renderTask?.cancel()
        let document = session.state.document
        let style = session.state.style
        renderTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 40_000_000)
                guard let self else { return }
                try await preview.render(document, style: style)
                try Task.checkCancellation()
                renderedDocument = document
                renderedStyle = style
                previewReady = !document.steps.isEmpty
                updateEnabledState()
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                previewReady = false
                // Do not recursively schedule a failing render through the session callback.
                renderedDocument = document
                renderedStyle = style
                session.report("预览失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    func textDidChange(_ notification: Notification) {
        session.edit { $0.input = inputView.string }
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === titleField {
            session.edit { $0.document.title = titleField.stringValue }
        } else if notification.object as? NSTextField === subtitleField {
            session.edit { $0.document.subtitle = subtitleField.stringValue }
        }
    }

    @objc private func modelChanged() {
        guard ModelProvider.allCases.indices.contains(modelBox.indexOfSelectedItem) else { return }
        session.selectProvider(ModelProvider.allCases[modelBox.indexOfSelectedItem])
    }

    @objc private func generate() { session.generate() }
    @objc private func cancel() { session.cancel() }
    @objc private func styleChanged() { session.edit { $0.style = FlowchartStyle.allCases[styleControl.selectedSegment] } }
    @objc private func formatChanged() { updateEnabledState() }

    @objc private func addStep() {
        session.edit { $0.document.steps.append(.init(title: "新步骤", description: "", kind: "process", iconID: "settings", nextLabel: "")) }
    }

    @objc private func zoomChanged() {
        let scales: [Double?] = [nil, 0.5, 1, 2]
        let scale = scales[zoomControl.indexOfSelectedItem]
        Task { [weak self] in try? await self?.preview.setZoom(scale) }
    }

    @objc private func exportFile() {
        guard let window, !isExporting else { return }
        let isPNG = formatControl.indexOfSelectedItem == 0
        let panel = NSSavePanel()
        panel.allowedContentTypes = isPNG ? [.png] : [.svg]
        let title = session.state.document.title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        panel.nameFieldStringValue = String(title.prefix(80)) + (isPNG ? ".png" : ".svg")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.performExport(isPNG: isPNG, destination: url) }
        }
    }

    @objc private func copyImage() {
        Task { [weak self] in await self?.performExport(isPNG: true, destination: nil) }
    }

    /// Hand off to Finder and close the panel while retaining the document for reopening.
    @objc private func showExportInFinder() {
        guard let lastExportURL else { return }
        revealExport(lastExportURL)
        close()
    }

    /// A completed save needs visible feedback above the canvas, with a direct action for that exact file.
    private func showExportConfirmation(for url: URL) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "导出成功"
        alert.informativeText = "文件：\(url.lastPathComponent)\n保存位置：\(url.deletingLastPathComponent().path)"
        alert.addButton(withTitle: "在 Finder 中显示")
        alert.addButton(withTitle: "完成")
        alert.beginSheetModal(for: window) { [weak self] response in
            // Done dismisses only the confirmation; revealing the file also closes the editor.
            guard response == .alertFirstButtonReturn else { return }
            self?.revealExport(url)
            self?.close()
        }
    }

    /// Flush the latest edits before saving, and always restore the native controls after an error.
    func performExport(isPNG: Bool, destination: URL?) async {
        guard !isExporting else { return }
        let document = session.state.document
        let style = session.state.style
        let longEdge = resolutionControl.selectedSegment == 1 ? 4800 : 2400
        renderTask?.cancel()
        isExporting = true
        refreshRows()
        updateEnabledState()
        defer {
            isExporting = false
            refreshRows()
            updateEnabledState()
        }
        do {
            try document.validate()
            try await preview.render(document, style: style)
            renderedDocument = document
            renderedStyle = style
            previewReady = true
            let data = try await (isPNG ? preview.pngData(longEdge: longEdge) : preview.svgData())
            if let destination {
                try data.write(to: destination, options: .atomic)
                lastExportURL = destination
                session.report("已导出：\(destination.lastPathComponent)", isError: false)
                showExportConfirmation(for: destination)
            } else {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setData(data, forType: .png) else {
                    throw FlowchartError.message("无法写入剪贴板，请重试。")
                }
                session.report("已复制图片", isError: false)
            }
        } catch {
            session.report(error.localizedDescription, isError: true)
        }
    }
}

/// Give every native input in this tool the same editing shortcuts as the existing polish panel.
private final class FlowchartWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if TextEditingShortcuts.perform(with: event, in: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
