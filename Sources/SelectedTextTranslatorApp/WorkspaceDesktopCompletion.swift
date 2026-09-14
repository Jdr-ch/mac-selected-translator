import Foundation

/// 每轮恢复按桌面收尾一次；失败重试沿用已成功窗口的结果，全部成功后再执行对齐。
@MainActor
final class WorkspaceDesktopCompletion {
    private var completedKeys: Set<String> = []

    /// 未全部完成时保持等待；空桌面无需对齐，任一窗口失败时跳过，对齐失败保留恢复成功结果供单独重试。
    func finish(_ desktop: WorkspaceDesktop, windows: [WorkspaceWindow], outcomes: [WorkspaceOutcome],
                align: () async throws -> Void, update: (WorkspaceDesktopActivity) -> Void) async {
        let key = desktop.selectionKey
        guard !completedKeys.contains(key) else { return }
        let entries = windows.filter { $0.desktop.selectionKey == key }
        let results = entries.compactMap { entry in outcomes.first { $0.windowID == entry.id } }
        guard results.count == entries.count else { return }
        completedKeys.insert(key)
        let failures = results.filter { $0.error != nil }.count
        guard failures == 0 else {
            update(WorkspaceDesktopActivity(message: "\(failures) 项失败 · 可重试", failed: true))
            return
        }
        guard !entries.isEmpty else {
            update(WorkspaceDesktopActivity(message: "已恢复 · 无窗口需要对齐"))
            return
        }
        update(WorkspaceDesktopActivity(message: "窗口已恢复 · 正在对齐…", running: true))
        do {
            try await align()
            update(WorkspaceDesktopActivity(message: "已恢复并对齐"))
        } catch {
            update(WorkspaceDesktopActivity(message: "窗口已恢复，对齐失败：\(error.localizedDescription)", failed: true))
        }
    }
}

/// 仅处理本场景已恢复且仍在目标桌面的窗口；不对其他桌面或临时出现在当前桌面的窗口执行布局。
@MainActor
enum WorkspaceDesktopAlignment {
    static func align(_ desktop: WorkspaceDesktop, windows: [WorkspaceWindow], outcomes: [WorkspaceOutcome]) async throws {
        let catalog = WorkspaceWindowCatalog()
        let target = try WorkspaceGeometry.resolve(desktop, in: catalog.desktop.desktops())
        let entries = windows.filter { $0.desktop.selectionKey == desktop.selectionKey }
        let available = try await catalog.windows(in: [target.spaceID])
        let selected = try matchingWindows(entries, outcomes: outcomes, available: available, spaceID: target.spaceID)
        let frames = try WindowLayoutController().alignRestoredWindows(selected, in: target.screenFrame)
        // AX 写入可能延迟生效；仅回读目标窗口，不重写、不再对齐，超时可单独重试对齐。
        let deadline = Date().addingTimeInterval(5)
        while true {
            let valid = try zip(selected, frames).allSatisfy { window, frame in
                guard try catalog.desktop.spaces(for: window.id) == [target.spaceID],
                      let current = WorkspaceWindowCatalog.frame(window.element) else { return false }
                return WorkspaceWindowCatalog.distance(current, frame) <= 8
            }
            if valid { return }
            guard Date() < deadline else { throw WorkspaceError.message("未能确认所有窗口已对齐，请重试失败项。") }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// 按模板顺序解析实际编号；缺失或已移动的窗口必须停止对齐，不能用同名窗口替代。
    static func matchingWindows(_ entries: [WorkspaceWindow], outcomes: [WorkspaceOutcome],
                                available: [WorkspaceNativeWindow], spaceID: UInt64) throws -> [WorkspaceNativeWindow] {
        var used: Set<UInt32> = []
        return try entries.map { entry in
            guard let result = outcomes.first(where: { $0.windowID == entry.id }), result.error == nil,
                  let id = result.nativeWindowID, used.insert(id).inserted,
                  let window = available.first(where: { $0.id == id && $0.bundleID == entry.bundleID && $0.spaceIDs == [spaceID] }) else {
                throw WorkspaceError.message("\(entry.label)已关闭或不在目标桌面，请重新恢复该桌面。")
            }
            return window
        }
    }
}
