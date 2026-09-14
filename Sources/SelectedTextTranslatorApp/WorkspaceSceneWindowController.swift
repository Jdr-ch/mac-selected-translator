import AppKit

/// 场景管理面板展示采集预览与逐项结果；修改只影响模板，不直接操作用户窗口。
@MainActor
final class WorkspaceSceneWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let session = WorkspaceSceneController()
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let details = NSTextView()
    private let captureButton = NSButton(title: "采集桌面 3、4、5", target: nil, action: nil)
    private let saveButton = NSButton(title: "保存场景", target: nil, action: nil)
    private let restoreButton = NSButton(title: "恢复场景", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试失败项", target: nil, action: nil)
    private let projectButton = NSButton(title: "选择项目…", target: nil, action: nil)
    private let rebindButton = NSButton(title: "重新绑定桌面…", target: nil, action: nil)
    private let removeButton = NSButton(title: "从模板移除", target: nil, action: nil)

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "工作场景"
        window.minSize = NSSize(width: 680, height: 620)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        session.onChange = { [weak self] in self?.refresh() }
        session.load()
    }

    required init?(coder: NSCoder) { fatalError("不使用归档初始化") }

    /// 菜单入口只展示管理窗口，用户在窗口内选择采集或恢复。
    func show() {
        window?.center()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "一次保存，一键回到工作状态")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "记录桌面 3、4、5 中的项目、网页群组与窗口布局。清单仅保存在本机。")
        subtitle.textColor = .secondaryLabelColor
        let actions = NSStackView(views: [captureButton, saveButton, restoreButton, retryButton])
        actions.spacing = 10
        let edits = NSStackView(views: [projectButton, rebindButton, removeButton])
        edits.spacing = 10
        let controls: [(NSButton, Selector)] = [(captureButton, #selector(capture)), (saveButton, #selector(save)),
            (restoreButton, #selector(restore)), (retryButton, #selector(retry)), (projectButton, #selector(selectProject)),
            (rebindButton, #selector(rebindDesktop)), (removeButton, #selector(removeEntry))]
        for (button, action) in controls { button.target = self; button.action = action; button.bezelStyle = .rounded }
        restoreButton.keyEquivalent = "\r"
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (id, label, width) in [("desktop", "目标桌面", 100.0), ("window", "项目与窗口", 330.0), ("result", "状态", 380.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = label
            column.width = width
            table.addTableColumn(column)
        }
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 38
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        scroll.documentView = table
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder
        details.isEditable = false
        details.isSelectable = true
        details.font = .systemFont(ofSize: 12)
        details.textContainerInset = NSSize(width: 8, height: 8)
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        detailScroll.documentView = details
        let stack = NSStackView(views: [title, subtitle, actions, scroll, edits, detailScroll, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            detailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailScroll.heightAnchor.constraint(equalToConstant: 150),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    /// busy、待补充项与失败结果驱动按钮状态，避免请求交错或未保存模板被恢复。
    private func refresh() {
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0, selected < numberOfRows(in: table) { table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false) }
        statusLabel.stringValue = session.status
        captureButton.isEnabled = !session.busy
        saveButton.isEnabled = !session.busy && session.scene?.windows.isEmpty == false
        restoreButton.isEnabled = !session.busy && session.scene != nil && !session.isDirty
        retryButton.isEnabled = !session.busy && session.outcomes.contains { $0.error != nil } && !session.isDirty
        refreshSelection()
    }

    private func refreshSelection() {
        let entry = selectedEntry()
        projectButton.isEnabled = !session.busy && entry?.bundleID == "com.jetbrains.WebStorm"
        rebindButton.isEnabled = !session.busy && entry != nil
        removeButton.isEnabled = !session.busy && entry != nil
        details.string = entry.map(detailText) ?? "选择窗口，查看项目路径、完整网址顺序和布局。"
    }

    /// 预览必须能够核对完整快照；表格保持简洁，所选项在下方展示所有标签与布局。
    private func detailText(_ entry: WorkspaceWindow) -> String {
        let frame = WorkspaceGeometry.absolute(entry.relativeFrame, in: entry.desktop.screenFrame)
        var lines = [entry.label, "\(entry.desktop.label) · 位置 (\(Int(frame.minX)), \(Int(frame.minY))) · 大小 \(Int(frame.width)) × \(Int(frame.height))"]
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

    private func selectedEntry() -> WorkspaceWindow? {
        guard let windows = session.scene?.windows, windows.indices.contains(table.selectedRow) else { return nil }
        return windows[table.selectedRow]
    }

    func numberOfRows(in tableView: NSTableView) -> Int { session.scene?.windows.count ?? 0 }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshSelection() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let entry = session.scene?.windows[row] else { return nil }
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "desktop": text = entry.desktop.label
        case "window": text = entry.label
        default:
            if let outcome = session.outcomes.first(where: { $0.windowID == entry.id }) { text = outcome.error ?? "已恢复并验证" }
            else { text = entry.issues.isEmpty ? "已采集" : entry.issues.joined(separator: "；") }
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = tableColumn?.identifier.rawValue == "window" ? entry.projectPath ?? text : text
        return label
    }

    @objc private func capture() { Task { await session.capture() } }
    @objc private func save() { session.save() }
    @objc private func restore() { Task { await session.restore() } }
    @objc private func retry() { Task { await session.restore(failedOnly: true) } }

    /// 用户选择的目录仅写入当前草稿，保存后才成为下次恢复的项目目标。
    @objc private func selectProject() {
        guard let entry = selectedEntry(), let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "为 \(entry.title) 选择 WebStorm 项目文件夹"
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let path = panel.url?.path, let self,
                  let index = self.session.scene?.windows.firstIndex(where: { $0.id == entry.id }) else { return }
            self.session.scene?.windows[index].projectPath = path
            self.session.scene?.windows[index].issues.removeAll { $0.contains("项目文件夹") }
            self.session.isDirty = true
            self.session.status = "项目已更新，请保存场景。"
            self.refresh()
        }
    }

    /// 桌面发生变化时要求明确选择当前目标，保留原相对布局而不按旧编号自动迁移。
    @objc private func rebindDesktop() {
        guard let entry = selectedEntry(), let window else { return }
        do {
            let desktops = try session.catalog.desktop.desktops()
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
            popup.addItems(withTitles: desktops.map { "\($0.label) · \($0.displayID.prefix(8))" })
            let alert = NSAlert()
            alert.messageText = "选择新的目标桌面"
            alert.informativeText = entry.label
            alert.accessoryView = popup
            alert.addButton(withTitle: "绑定")
            alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let self, desktops.indices.contains(popup.indexOfSelectedItem),
                      let index = self.session.scene?.windows.firstIndex(where: { $0.id == entry.id }) else { return }
                self.session.scene?.windows[index].desktop = desktops[popup.indexOfSelectedItem]
                self.session.isDirty = true
                self.session.status = "桌面绑定已更新，请保存场景。"
                self.refresh()
            }
        } catch { session.status = error.localizedDescription; refresh() }
    }

    /// 移除仅影响待保存模板，不关闭或移动真实窗口。
    @objc private func removeEntry() {
        guard let entry = selectedEntry() else { return }
        session.scene?.windows.removeAll { $0.id == entry.id }
        session.isDirty = true
        session.status = "已从模板移除此项，请保存场景。"
        refresh()
    }
}
