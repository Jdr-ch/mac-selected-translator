import Foundation

/// 每个桌面单独持有采集草稿；Chrome 资料只在该桌面包含浏览器窗口时参与保存校验。
struct WorkspaceDesktopDraft {
    var desktop: WorkspaceDesktop
    var windows: [WorkspaceWindow]
    var profileToken: String = ""
    var profileDirectory: String = ""
}

/// 保存模板与草稿分开管理，恢复始终读取 saved，其他桌面的未保存修改不会阻止恢复。
struct WorkspaceSceneDrafts {
    var saved: WorkspaceScene?
    var drafts: [String: WorkspaceDesktopDraft] = [:]

    /// 恢复范围只读取保存版本；失败重试可进一步限定窗口编号，未勾选桌面始终排除。
    func restorationEntries(for keys: Set<String>, failedIDs: Set<String>? = nil) -> [WorkspaceWindow] {
        saved?.windows.filter { keys.contains($0.desktop.selectionKey) && (failedIDs == nil || failedIDs!.contains($0.id)) } ?? []
    }

    /// 桌面行优先展示草稿，未重新采集的桌面沿用已经保存的窗口清单。
    func windows(for key: String) -> [WorkspaceWindow] {
        drafts[key]?.windows ?? saved?.windows.filter { $0.desktop.selectionKey == key } ?? []
    }

    /// 修改单个窗口前复制所属桌面的快照，避免对已保存模板产生隐式写入。
    mutating func edit(_ entry: WorkspaceWindow, change: (inout WorkspaceWindow) -> Void) {
        let key = entry.desktop.selectionKey
        var draft = drafts[key] ?? WorkspaceDesktopDraft(desktop: entry.desktop, windows: windows(for: key),
            profileToken: saved?.profileToken ?? "", profileDirectory: saved?.chromeProfileDirectory ?? "")
        guard let index = draft.windows.firstIndex(where: { $0.id == entry.id }) else { return }
        change(&draft.windows[index])
        drafts[key] = draft
    }

    /// 移除最后一个窗口也保留空桌面草稿，保存后该桌面仍出现在默认恢复选择中。
    mutating func remove(_ entry: WorkspaceWindow) {
        edit(entry) { _ in }
        drafts[entry.desktop.selectionKey]?.windows.removeAll { $0.id == entry.id }
    }

    /// 仅合并指定桌面；写盘成功后才清理该草稿，失败时保留磁盘模板和全部待保存修改。
    mutating func save(_ key: String, to store: WorkspaceSceneStore) throws {
        guard let draft = drafts[key] else { return }
        guard draft.windows.allSatisfy({ $0.issues.isEmpty }) else {
            throw WorkspaceError.message("\(draft.desktop.label)有待补充条目，请展开检查后保存。")
        }
        var merged = saved ?? WorkspaceScene(profileToken: "", chromeProfileDirectory: "", windows: [])
        let retained = merged.windows.filter { $0.desktop.selectionKey != key }
        if draft.windows.contains(where: { $0.chrome != nil }) {
            guard !draft.profileToken.isEmpty, !draft.profileDirectory.isEmpty else {
                throw WorkspaceError.message("\(draft.desktop.label)缺少 Chrome 资料信息，请重新采集。")
            }
            guard !retained.contains(where: { $0.chrome != nil }) || merged.chromeProfileDirectory == draft.profileDirectory else {
                throw WorkspaceError.message("所选桌面的 Chrome 资料与其他已保存桌面不同，请使用同一浏览器资料。")
            }
            merged.profileToken = draft.profileToken
            merged.chromeProfileDirectory = draft.profileDirectory
        }
        merged.desktops = merged.savedDesktops.filter { $0.selectionKey != key } + [draft.desktop]
        merged.windows = (retained + draft.windows).sorted { $0.desktop.ordinal < $1.desktop.ordinal }
        merged.savedAt = Date()
        try store.save(merged)
        saved = merged
        drafts.removeValue(forKey: key)
    }

    /// 明确确认后原子保存整个桌面的新绑定，源和目标同时更新，不会留下重复窗口。
    mutating func rebind(_ source: WorkspaceDesktop, to target: WorkspaceDesktop, store: WorkspaceSceneStore) throws {
        let sourceKey = source.selectionKey
        let targetKey = target.selectionKey
        guard drafts[sourceKey] == nil, drafts[targetKey] == nil else {
            throw WorkspaceError.message("请先保存源桌面和目标桌面的草稿，再重新绑定。")
        }
        guard var merged = saved, merged.savedDesktops.contains(where: { $0.selectionKey == sourceKey }) else {
            throw WorkspaceError.message("请先保存该桌面，再重新绑定。")
        }
        merged.desktops = merged.savedDesktops.filter { ![sourceKey, targetKey].contains($0.selectionKey) } + [target]
        for index in merged.windows.indices where merged.windows[index].desktop.selectionKey == sourceKey {
            merged.windows[index].desktop = target
        }
        merged.savedAt = Date()
        try store.save(merged)
        saved = merged
    }
}
