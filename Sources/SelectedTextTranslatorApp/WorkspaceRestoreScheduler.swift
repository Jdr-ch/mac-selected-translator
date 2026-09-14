import Foundation

/// 异步独占入口只保护共享资源；等待不会阻塞主线程，释放后按请求顺序交给下一项。
@MainActor
final class WorkspaceOperationGate {
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !occupied { occupied = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }
}

/// 控制同时启动的窗口数量；任务结束立即补位，单项错误不取消其他桌面的恢复。
@MainActor
enum WorkspaceRestoreScheduler {
    static func run(_ entries: [WorkspaceWindow], limit: Int = 4,
                    operation: @escaping @MainActor (WorkspaceWindow) async -> WorkspaceOutcome,
                    finished: @escaping @MainActor (WorkspaceOutcome) -> Void) async -> [WorkspaceOutcome] {
        await withTaskGroup(of: (Int, WorkspaceOutcome).self) { group in
            var next = 0
            var results: [Int: WorkspaceOutcome] = [:]
            func enqueue() {
                guard next < entries.count else { return }
                let index = next
                let entry = entries[index]
                next += 1
                group.addTask { (index, await operation(entry)) }
            }
            for _ in 0..<min(max(limit, 1), entries.count) { enqueue() }
            while let (index, outcome) = await group.next() {
                results[index] = outcome
                finished(outcome)
                enqueue()
            }
            return entries.indices.compactMap { results[$0] }
        }
    }
}

/// 在启动应用前准备全部目标桌面；添加会改变后续显示器的编号，因此最后统一重新解析。
@MainActor
enum WorkspaceDesktopPreparation {
    static func prepare(_ requested: [WorkspaceDesktop],
                        read: () throws -> [WorkspaceDesktop],
                        add: (String) async throws -> Void,
                        progress: (String) -> Void = { _ in }) async -> [String: Result<WorkspaceDesktop, Error>] {
        do {
            var topology = try read()
            var seen: Set<String> = []
            let displays = topology.map(\.displayID).filter { seen.insert($0).inserted }
            var failures: [String: Error] = [:]
            for displayID in displays {
                let targets = requested.filter { $0.displayID == displayID }
                guard let highest = targets.map(\.ordinal).max() else { continue }
                do {
                    var current = topology.filter { $0.displayID == displayID }
                    // 普通桌面只能追加；无法通过追加获得更小的跨显示器编号时要求显式重绑。
                    guard let first = current.first, targets.allSatisfy({ $0.ordinal >= first.ordinal }),
                          highest - first.ordinal < 16 else {
                        throw WorkspaceError.message("桌面编号与显示器布局不匹配，请重新绑定目标桌面。")
                    }
                    while let last = current.last, last.ordinal < highest {
                        guard current.count < 16 else { throw WorkspaceError.message("该显示器已达到 16 个普通桌面的创建上限。") }
                        progress(displayID)
                        let previousIDs = Set(current.map(\.spaceID))
                        try await add(displayID)
                        topology = try read()
                        current = topology.filter { $0.displayID == displayID }
                        let currentIDs = Set(current.map(\.spaceID))
                        guard currentIDs.count == previousIDs.count + 1, previousIDs.isSubset(of: currentIDs) else {
                            throw WorkspaceError.message("未确认新桌面创建成功，已停止继续创建，请检查调度中心后重试。")
                        }
                    }
                } catch { failures[displayID] = error }
            }
            topology = try read()
            var results: [String: Result<WorkspaceDesktop, Error>] = [:]
            for desktop in requested {
                // 创建失败不影响同一显示器上原本存在且仍能匹配的桌面。
                if let resolved = try? WorkspaceGeometry.resolve(desktop, in: topology) {
                    results[desktop.selectionKey] = .success(resolved)
                } else {
                    results[desktop.selectionKey] = .failure(failures[desktop.displayID]
                        ?? WorkspaceError.message("未找到原显示器上的\(desktop.label)，请重新绑定。"))
                }
            }
            return results
        } catch {
            return Dictionary(requested.map { ($0.selectionKey, .failure(error)) }, uniquingKeysWith: { first, _ in first })
        }
    }
}
