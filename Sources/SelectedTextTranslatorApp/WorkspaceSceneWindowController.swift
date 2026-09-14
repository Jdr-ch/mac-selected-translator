import AppKit

/// 背景层随系统外观刷新，保持 B 方案的浅灰面板、白色卡片和细分隔线。
@MainActor
private final class WorkspaceSceneSurface: NSView {
    var surfaceColor = WorkspaceScenePalette.window
    var bordered = false
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAppearance() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAppearance() }
    func updateAppearance() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = surfaceColor.cgColor
            layer?.borderColor = WorkspaceScenePalette.line.cgColor
        }
        layer?.borderWidth = bordered ? 1 : 0
        layer?.cornerRadius = bordered ? 9 : 0
    }
}

private final class WorkspaceDesktopStack: NSStackView {
    override var isFlipped: Bool { true }
}

/// B 方案：桌面卡片与窗口 tabs 共享 session；浏览明细与批量勾选相互独立。
@MainActor
final class WorkspaceSceneWindowController: NSWindowController, NSWindowDelegate {
    let session = WorkspaceSceneController()
    private let cards = WorkspaceDesktopStack()
    private let scroll = NSScrollView()
    private var cardViews: [String: WorkspaceDesktopCardView] = [:]
    private var cardHeights: [String: NSLayoutConstraint] = [:]
    /// 明细焦点与恢复勾选分离：行内操作可查看该桌面，不修改批量操作范围。
    private var focusedDesktopKey: String?
    private var focusedWindowID: String?
    /// 只在切换窗口时回到详情顶部；执行结果刷新不打断用户阅读长网址清单。
    private var displayedWindowID: String?
    private var detailEntries: [WorkspaceWindow] = []
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let selectionLabel = NSTextField(labelWithString: "")
    private let details = NSTextView()
    private let detailTitle = NSTextField(labelWithString: "窗口详情")
    private let windowTabs = WorkspaceWindowTabsView()
    private let selectAllButton = NSButton(checkboxWithTitle: "全选", target: nil, action: nil)
    private let refreshButton = WorkspaceSceneButton(title: "刷新桌面", target: nil, action: nil)
    private let captureButton = WorkspaceSceneButton(title: "采集所选", target: nil, action: nil)
    private let saveButton = WorkspaceSceneButton(title: "保存所选", target: nil, action: nil)
    private let restoreButton = WorkspaceSceneButton(title: "恢复所选", target: nil, action: nil)
    private let retryButton = WorkspaceSceneButton(title: "重试失败项", target: nil, action: nil)
    private let projectButton = WorkspaceSceneButton(title: "选择项目…", target: nil, action: nil)
    private let rebindButton = WorkspaceSceneButton(title: "重新绑定桌面…", target: nil, action: nil)
    private let removeButton = WorkspaceSceneButton(title: "从模板移除窗口", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "工作场景"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 740, height: 640)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        session.onChange = { [weak self] in self?.refresh() }
        session.load()
    }

    required init?(coder: NSCoder) { fatalError("不使用归档初始化") }

    func show() {
        session.refreshDesktops()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        layoutCards()
    }

    private func buildContent() {
        guard let window else { return }
        let content = WorkspaceSceneSurface()
        window.contentView = content
        content.updateAppearance()
        let title = NSTextField(labelWithString: "工作场景")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = WorkspaceScenePalette.text
        title.alignment = .center
        let header = NSView()
        header.addSubview(title)
        title.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([title.centerXAnchor.constraint(equalTo: header.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor)])
        let divider = NSBox()
        divider.boxType = .separator
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [selectAllButton, selectionLabel, spacer, captureButton, saveButton, restoreButton])
        actions.spacing = 8
        selectionLabel.font = .systemFont(ofSize: 12)
        selectionLabel.textColor = WorkspaceScenePalette.secondary
        let tools = NSStackView(views: [refreshButton, retryButton])
        tools.spacing = 8
        let controls: [(NSButton, Selector)] = [(selectAllButton, #selector(toggleAllDesktops)), (refreshButton, #selector(refreshDesktops)),
            (captureButton, #selector(capture)), (saveButton, #selector(save)), (restoreButton, #selector(restore)),
            (retryButton, #selector(retry)), (projectButton, #selector(selectProject)), (rebindButton, #selector(rebindDesktop)),
            (removeButton, #selector(removeEntry))]
        for (button, action) in controls { button.target = self; button.action = action; button.isBordered = false }
        selectAllButton.allowsMixedState = true
        for button in [refreshButton, retryButton, projectButton, rebindButton, removeButton] { button.style = .link }
        restoreButton.style = .primary
        restoreButton.keyEquivalent = "\r"
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 8
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = cards
        let detailSurface = buildDetails()
        let footer = NSTextField(labelWithString: "默认勾选已保存桌面 · 保存仅更新所选桌面")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = WorkspaceScenePalette.secondary
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = WorkspaceScenePalette.secondary
        for view in [header, divider, actions, tools, scroll, detailSurface, footer, statusLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor), header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor), header.heightAnchor.constraint(equalToConstant: 44),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor), divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor), divider.heightAnchor.constraint(equalToConstant: 1),
            actions.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16), actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), actions.heightAnchor.constraint(equalToConstant: 30),
            tools.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 6), tools.leadingAnchor.constraint(equalTo: actions.leadingAnchor),
            tools.heightAnchor.constraint(equalToConstant: 26), scroll.topAnchor.constraint(equalTo: tools.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: actions.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            detailSurface.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            detailSurface.leadingAnchor.constraint(equalTo: actions.leadingAnchor), detailSurface.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            detailSurface.heightAnchor.constraint(equalToConstant: 236), footer.topAnchor.constraint(equalTo: detailSurface.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: actions.leadingAnchor), statusLabel.topAnchor.constraint(equalTo: footer.bottomAnchor, constant: 7),
            statusLabel.leadingAnchor.constraint(equalTo: actions.leadingAnchor), statusLabel.trailingAnchor.constraint(equalTo: actions.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14)
        ])
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    /// 窗口详情保留全部网址、群组、项目和编辑入口，改用与桌面卡片一致的圆角白色区域。
    private func buildDetails() -> NSView {
        let surface = WorkspaceSceneSurface()
        surface.surfaceColor = WorkspaceScenePalette.content
        surface.bordered = true
        surface.updateAppearance()
        detailTitle.font = .systemFont(ofSize: 13, weight: .medium)
        detailTitle.textColor = WorkspaceScenePalette.text
        windowTabs.onSelect = { [weak self] id in self?.focusedWindowID = id; self?.refreshDetails() }
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false
        details.isEditable = false
        details.isSelectable = true
        details.drawsBackground = false
        details.textColor = WorkspaceScenePalette.text
        details.font = .systemFont(ofSize: 12)
        details.textContainerInset = NSSize(width: 2, height: 4)
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        detailScroll.documentView = details
        let edits = NSStackView(views: [projectButton, rebindButton, removeButton])
        edits.spacing = 12
        for view in [detailTitle, windowTabs, detailScroll, edits] { view.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(view) }
        NSLayoutConstraint.activate([
            detailTitle.topAnchor.constraint(equalTo: surface.topAnchor, constant: 10), detailTitle.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            detailTitle.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -14), detailTitle.heightAnchor.constraint(equalToConstant: 20),
            windowTabs.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 4), windowTabs.leadingAnchor.constraint(equalTo: detailTitle.leadingAnchor),
            windowTabs.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14), windowTabs.heightAnchor.constraint(equalToConstant: 38),
            detailScroll.topAnchor.constraint(equalTo: windowTabs.bottomAnchor, constant: 6), detailScroll.leadingAnchor.constraint(equalTo: detailTitle.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -14),
            edits.topAnchor.constraint(equalTo: detailScroll.bottomAnchor, constant: 5), edits.leadingAnchor.constraint(equalTo: detailTitle.leadingAnchor),
            edits.heightAnchor.constraint(equalToConstant: 26), edits.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -8)
        ])
        return surface
    }

    /// 卡片对象按桌面键复用，阶段更新不会重新创建运行光带。
    private func refresh() {
        let desktops = session.desktops
        let keys = Set(desktops.map(\.selectionKey))
        for key in Set(cardViews.keys).subtracting(keys) {
            if let view = cardViews.removeValue(forKey: key) { cards.removeArrangedSubview(view); view.removeFromSuperview() }
            cardHeights.removeValue(forKey: key)
        }
        for (index, desktop) in desktops.enumerated() {
            let key = desktop.selectionKey
            let card = cardViews[key] ?? WorkspaceDesktopCardView()
            if cardViews[key] == nil {
                cardViews[key] = card
                let height = card.heightAnchor.constraint(equalToConstant: 90)
                height.isActive = true
                cardHeights[key] = height
                card.onToggle = { [weak self] in self?.toggleDesktop(key) }
                card.onFocus = { [weak self] in self?.focus(key) }
                card.onCapture = { [weak self] in self?.focus(key); Task { await self?.session.capture(keys: [key]) } }
                card.onSave = { [weak self] in self?.focus(key); self?.session.save(keys: [key]) }
                card.onRestore = { [weak self] in self?.focus(key); Task { await self?.session.restore(keys: [key]) } }
                cards.insertArrangedSubview(card, at: index)
                card.widthAnchor.constraint(equalTo: cards.widthAnchor).isActive = true
            }
            card.configure(desktop: desktop, windows: session.library.windows(for: key), displayName: displayName(desktop),
                saved: session.savedKeys.contains(key), draft: session.library.drafts[key] != nil,
                selected: session.selectedKeys.contains(key), activity: session.activity(for: desktop), busy: session.busy,
                canCapture: session.canCapture(key), canSave: session.canSave(key), canRestore: session.canRestore(key), outcomes: session.outcomes)
        }
        if focusedDesktopKey == nil || !keys.contains(focusedDesktopKey!) {
            focusedDesktopKey = desktops.first(where: { session.savedKeys.contains($0.selectionKey) })?.selectionKey ?? desktops.first?.selectionKey
            focusedWindowID = nil
        }
        statusLabel.stringValue = session.status
        selectionLabel.stringValue = "已勾选 \(session.selectedKeys.count) 个桌面"
        selectAllButton.state = session.selectedKeys.isEmpty ? .off : (keys.isSubset(of: session.selectedKeys) ? .on : .mixed)
        selectAllButton.isEnabled = !session.busy
        refreshButton.isEnabled = !session.busy
        captureButton.isEnabled = session.selectedKeys.contains { session.canCapture($0) }
        saveButton.isEnabled = session.selectedKeys.contains { session.canSave($0) }
        restoreButton.isEnabled = session.selectedKeys.contains { session.canRestore($0) }
        retryButton.isEnabled = !session.busy && !session.selectedKeys.intersection(session.failedKeys).isEmpty
        refreshDetails()
        layoutCards()
    }

    /// 卡片高度由实际标题换行决定；长桌面清单滚动展示，详情与操作区保持可见。
    private func layoutCards() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let width = scroll.contentSize.width
        var height = CGFloat(max(cardViews.count - 1, 0)) * 8
        for (key, card) in cardViews {
            let rowHeight = card.preferredHeight(for: width)
            cardHeights[key]?.constant = rowHeight
            height += rowHeight
        }
        cards.frame = NSRect(x: 0, y: 0, width: width, height: height)
        cards.layoutSubtreeIfNeeded()
    }
    func windowDidResize(_ notification: Notification) { layoutCards() }

    private func displayName(_ desktop: WorkspaceDesktop) -> String {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { continue }
            if CFUUIDCreateString(nil, uuid) as String == desktop.displayID {
                return CGDisplayIsBuiltin(number) != 0 ? "内建显示器" : screen.localizedName
            }
        }
        return "显示器未连接"
    }

    private func selectedDesktop() -> WorkspaceDesktop? { session.desktops.first { $0.selectionKey == focusedDesktopKey } }
    private func selectedEntry() -> WorkspaceWindow? { detailEntries.first { $0.id == focusedWindowID } }

    private func refreshDetails() {
        detailEntries = focusedDesktopKey.map { session.library.windows(for: $0) } ?? []
        if !detailEntries.contains(where: { $0.id == focusedWindowID }) {
            // 首次进入桌面或重新采集后优先定位缺项，再定位恢复失败；正常刷新保留用户当前 tab。
            focusedWindowID = detailEntries.first(where: { !$0.issues.isEmpty })?.id
                ?? detailEntries.first(where: { entry in session.outcomes.contains { $0.windowID == entry.id && $0.error != nil } })?.id
                ?? detailEntries.first?.id
        }
        windowTabs.configure(detailEntries.map { entry in
            WorkspaceWindowPresentation(entry, outcome: session.outcomes.first { $0.windowID == entry.id })
        }, selectedID: focusedWindowID)
        detailTitle.stringValue = (selectedDesktop()?.label ?? "桌面") + " · 窗口详情"
        projectButton.isEnabled = !session.busy && selectedEntry()?.bundleID == "com.jetbrains.WebStorm"
        rebindButton.isEnabled = !session.busy && focusedDesktopKey.map { session.savedKeys.contains($0) } == true
        removeButton.isEnabled = !session.busy && selectedEntry() != nil
        if let entry = selectedEntry() { details.string = detailText(entry) }
        else if let desktop = selectedDesktop() { details.string = "\(desktop.label) · \(session.activity(for: desktop).message)\n采集后可在这里检查窗口、群组和布局。" }
        else { details.string = "点击桌面卡片查看窗口详情；通过复选框勾选需要操作的桌面。" }
        if displayedWindowID != focusedWindowID {
            displayedWindowID = focusedWindowID
            details.scrollToBeginningOfDocument(nil)
        }
    }

    /// 浏览桌面不修改批量范围；重复点击同一桌面保留已选窗口 tab，运行期间仍能查看结果。
    private func focus(_ key: String) {
        if focusedDesktopKey != key { focusedWindowID = nil }
        focusedDesktopKey = key
        refreshDetails()
    }
    private func toggleDesktop(_ key: String) {
        guard !session.busy else { return }
        if session.selectedKeys.contains(key) { session.selectedKeys.remove(key) } else { session.selectedKeys.insert(key) }
        focus(key)
        refresh()
    }
    @objc private func toggleAllDesktops() {
        let keys = Set(session.desktops.map(\.selectionKey))
        session.selectedKeys = keys.isSubset(of: session.selectedKeys) ? [] : keys
        refresh()
    }
    @objc private func refreshDesktops() { session.refreshDesktops() }
    @objc private func capture() { Task { await session.capture() } }
    @objc private func save() { session.save() }
    @objc private func restore() { Task { await session.restore() } }
    @objc private func retry() { Task { await session.restore(failedOnly: true) } }

    @objc private func selectProject() {
        guard let entry = selectedEntry(), let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "为 \(entry.title) 选择 WebStorm 项目文件夹"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let path = panel.url?.path else { return }
            self?.session.updateProject(entry, path: path)
        }
    }

    /// 重新绑定仍作用于整桌面模板，确认后原子保存，保留目标桌面已有窗口。
    @objc private func rebindDesktop() {
        guard let desktop = selectedDesktop(), let window else { return }
        session.refreshDesktops()
        let targets = session.currentDesktops
        guard !targets.isEmpty else { return }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 340, height: 28))
        popup.addItems(withTitles: targets.map { "\($0.label) · \($0.displayID.prefix(8))" })
        let alert = NSAlert()
        alert.messageText = "重新绑定 \(desktop.label) 的所有窗口"
        alert.informativeText = "保存到新的目标桌面，保留目标已有模板。此操作不会移动真实窗口。"
        alert.accessoryView = popup
        alert.addButton(withTitle: "绑定并保存")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, targets.indices.contains(popup.indexOfSelectedItem) else { return }
            self?.session.rebind(desktop, to: targets[popup.indexOfSelectedItem])
        }
    }
    @objc private func removeEntry() { if let entry = selectedEntry() { session.remove(entry) } }
    /// 单项明细保留完整网址顺序、群组属性与布局；失败原因不依赖被截断的行内摘要。
    private func detailText(_ entry: WorkspaceWindow) -> String {
        let frame = WorkspaceGeometry.absolute(entry.relativeFrame, in: entry.desktop.screenFrame)
        let pending = session.library.issues(for: entry.desktop.selectionKey)
        var lines = pending.isEmpty ? [] : ["待补充信息（处理后保存本桌面）"] + pending + [""]
        let activity = session.activity(for: entry.desktop)
        if activity.failed { lines += [activity.message, ""] }
        lines += [entry.label, "\(entry.desktop.label) · 位置 (\(Int(frame.minX)), \(Int(frame.minY))) · 大小 \(Int(frame.width)) × \(Int(frame.height))"]
        if let outcome = session.outcomes.first(where: { $0.windowID == entry.id }) {
            lines.append(outcome.error.map { "恢复失败：\($0)" } ?? "已恢复并验证")
        }
        if let path = entry.projectPath { lines.append("项目：\(path)") }
        if let chrome = entry.chrome {
            let colors = ["grey": "灰色", "blue": "蓝色", "red": "红色", "yellow": "黄色", "green": "绿色",
                "pink": "粉色", "purple": "紫色", "cyan": "青色", "orange": "橙色"]
            for group in chrome.groups {
                lines.append("群组：\(group.title) · \(colors[group.color] ?? group.color) · \(group.collapsed ? "已折叠" : "已展开")")
            }
            for (index, tab) in chrome.tabs.enumerated() {
                let name = chrome.groups.first(where: { $0.id == tab.groupId })?.title ?? "未分组"
                lines.append("\(index + 1). [\(name)]\(tab.pinned ? " [固定]" : "")\(tab.active ? " [当前选中]" : "") \(tab.title)\n   \(tab.url)")
            }
        }
        return lines.joined(separator: "\n")
    }


}
