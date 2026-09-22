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

/// 控制窗口并发；WebStorm 共用 IDE 启动入口，必须等前一项目打开、定位完成再执行下一项。
@MainActor
enum WorkspaceRestoreScheduler {
    static func run(_ entries: [WorkspaceWindow], limit: Int = 4,
                    operation: @escaping @MainActor (WorkspaceWindow) async -> WorkspaceOutcome,
                    finished: @escaping @MainActor (WorkspaceOutcome) async -> Void) async -> [WorkspaceOutcome] {
        await withTaskGroup(of: (Int, WorkspaceOutcome).self) { group in
            var pending = Array(entries.indices)
            var active: Set<Int> = []
            var results: [Int: WorkspaceOutcome] = [:]
            func enqueue() {
                while active.count < max(limit, 1) {
                    let openingWebStorm = active.contains { entries[$0].bundleID == "com.jetbrains.WebStorm" }
                    // 正在等待的 IDE 项目不占用执行名额，其他应用仍可继续恢复。
                    guard let offset = pending.firstIndex(where: {
                        !openingWebStorm || entries[$0].bundleID != "com.jetbrains.WebStorm"
                    }) else { return }
                    let index = pending.remove(at: offset)
                    let entry = entries[index]
                    active.insert(index)
                    group.addTask { (index, await operation(entry)) }
                }
            }
            enqueue()
            while let (index, outcome) = await group.next() {
                active.remove(index)
                results[index] = outcome
                await finished(outcome)
                enqueue()
            }
            return entries.indices.compactMap { results[$0] }
        }
    }
}

/// 在启动应用前准备全部目标桌面；每块显示器优先复用未占用的普通桌面，没有空桌面才追加创建。
@MainActor
enum WorkspaceDesktopPreparation {
    static func prepare(_ requested: [WorkspaceDesktop],
                        read: () throws -> [WorkspaceDesktop],
                        add: (String) async throws -> Void,
                        progress: (String) -> Void = { _ in },
                        empty: ([WorkspaceDesktop]) throws -> Set<UInt64> = { _ in [] }) async -> [String: Result<WorkspaceDesktop, Error>] {
        do {
            var topology = try read()
            var emptySpaceIDs = try empty(topology)
            var assignedSpaceIDs: Set<UInt64> = []
            var failures: [String: Error] = [:]
            var results: [String: Result<WorkspaceDesktop, Error>] = [:]
            for desktop in requested {
                let key = desktop.selectionKey
                do {
                    if let failure = failures[desktop.displayID] { throw failure }
                    var current = topology.filter { $0.displayID == desktop.displayID }.sorted { $0.ordinal < $1.ordinal }
                    guard !current.isEmpty else {
                        throw WorkspaceError.message("目标显示器已断开，无法恢复\(desktop.label)。")
                    }
                    let available = current.filter { !assignedSpaceIDs.contains($0.spaceID) }
                    // 同一个 Space 仍存在且为空时优先复用；否则选择该显示器上的任意空桌面。
                    if let target = available.first(where: { $0.id == desktop.id && emptySpaceIDs.contains($0.spaceID) })
                        ?? available.first(where: { emptySpaceIDs.contains($0.spaceID) }) {
                        assignedSpaceIDs.insert(target.spaceID)
                        results[key] = .success(target)
                        continue
                    }
                    guard current.count < 16 else {
                        throw WorkspaceError.message("该显示器已达到 16 个普通桌面的创建上限，且没有空桌面可用。")
                    }
                    let previousIDs = Set(current.map(\.spaceID))
                    progress(desktop.displayID)
                    try await add(desktop.displayID)
                    topology = try read()
                    current = topology.filter { $0.displayID == desktop.displayID }.sorted { $0.ordinal < $1.ordinal }
                    let created = current.first { !previousIDs.contains($0.spaceID) && !assignedSpaceIDs.contains($0.spaceID) }
                    guard let created else {
                        throw WorkspaceError.message("未确认新桌面创建成功，已停止继续创建，请检查调度中心后重试。")
                    }
                    emptySpaceIDs = try empty(topology)
                    assignedSpaceIDs.insert(created.spaceID)
                    results[key] = .success(created)
                } catch {
                    failures[desktop.displayID] = error
                    results[key] = .failure(error)
                }
            }
            return results
        } catch {
            return Dictionary(requested.map { ($0.selectionKey, .failure(error)) }, uniquingKeysWith: { first, _ in first })
        }
    }
}
