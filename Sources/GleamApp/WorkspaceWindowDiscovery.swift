import AppKit
import ApplicationServices
import Darwin

/// WindowServer 可跨桌面枚举；可变缓存仅在专属串行队列访问，因此允许跨 actor 持有此扫描器。
final class WorkspaceWindowDiscovery: @unchecked Sendable {
    private typealias WindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32
    private typealias RemoteElement = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private static let accessibility = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private let queue = DispatchQueue(label: "workspace.window-discovery", qos: .userInitiated)
    // 仅由串行队列更新；缓存先验证原生编号，未完成扫描在相同目标下从断点继续。
    private var cache: [pid_t: [UInt32: AXUIElement]] = [:]
    private var scans: [pid_t: (pending: Set<UInt32>, nextID: UInt64)] = [:]

    struct Result {
        var elements: [UInt32: AXUIElement]
        var missing: Set<UInt32>
    }

    /// 只操作其他进程的辅助功能对象，不在后台调用自身 AppKit，也不激活或切换桌面。
    func resolve(_ requested: [pid_t: Set<UInt32>]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    var elements: [UInt32: AXUIElement] = [:]
                    for (pid, ids) in requested where pid != getpid() {
                        elements.merge(try resolveProcess(pid, ids: ids)) { first, _ in first }
                    }
                    let expected = Set(requested.values.flatMap { $0 })
                    continuation.resume(returning: Result(elements: elements, missing: expected.subtracting(elements.keys)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// AX 到 WindowServer 编号的接口在 ApplicationServices 中；编号只用于本次实时关联。
    static func windowID(_ element: AXUIElement) throws -> UInt32 {
        let get: WindowID = try symbol("_AXUIElementGetWindow")
        var id: UInt32 = 0
        guard get(element, &id) == 0, id != 0 else { throw WorkspaceError.message("窗口没有可用的系统编号。") }
        return id
    }

    /// 先读应用发布的窗口、主窗口和焦点窗口；仅缺失的系统窗口需要扫描远程 AX 根节点。
    private func resolveProcess(_ pid: pid_t, ids: Set<UInt32>) throws -> [UInt32: AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var found = (cache[pid] ?? [:]).filter { ids.contains($0.key) && (try? Self.windowID($0.value)) == $0.key }
        var published: [AXUIElement] = Self.read(app, kAXWindowsAttribute) ?? []
        for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            if let element: AXUIElement = Self.read(app, attribute) { published.append(element) }
        }
        for element in published {
            if let id = try? Self.windowID(element), ids.contains(id), Self.isWindowRoot(element) { found[id] = element }
        }
        var missing = ids.subtracting(found.keys)
        if !missing.isEmpty {
            let create: RemoteElement = try Self.symbol("_AXUIElementCreateWithRemoteToken")
            // 远程令牌布局为 pid/保留位/coco 标记/UInt64 元素编号；只接受目标窗口的 AXWindow 根。
            // API 约束参照 AltTab 的 WindowElementAcquisition；子控件也会返回所属窗口编号，必须检查角色。
            var token = Data(count: 20)
            withUnsafeBytes(of: pid) { token.replaceSubrange(0..<4, with: $0) }
            withUnsafeBytes(of: UInt32(0x636f636f)) { token.replaceSubrange(8..<12, with: $0) }
            let previous = scans[pid]
            var cursor = previous?.pending == missing ? previous!.nextID : 0
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while !missing.isEmpty && ProcessInfo.processInfo.systemUptime < deadline && cursor < UInt64.max {
                withUnsafeBytes(of: cursor) { token.replaceSubrange(12..<20, with: $0) }
                cursor += 1
                guard let candidate = create(token as CFData)?.takeRetainedValue() else { continue }
                AXUIElementSetMessagingTimeout(candidate, 0.05)
                guard let id = try? Self.windowID(candidate), missing.contains(id), Self.isWindowRoot(candidate) else { continue }
                found[id] = candidate
                missing.remove(id)
            }
            scans[pid] = (missing, cursor)
        }
        cache[pid] = found
        return found
    }

    private static func isWindowRoot(_ element: AXUIElement) -> Bool {
        read(element, kAXRoleAttribute) as String? == kAXWindowRole
    }

    private static func read<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    /// 私有接口不可用时显式停止采集，避免把当前桌面的子集误当完整模板。
    private static func symbol<T>(_ name: String) throws -> T {
        guard let accessibility, let pointer = dlsym(accessibility, name) else {
            throw WorkspaceError.message("当前 macOS 缺少跨桌面窗口读取接口，请更新 App。")
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}

/// 原生清单中的窗口描述；即使 AX 暂时无响应，也保留它以便在预览中标明未完成项。
struct WorkspaceWindowSurface {
    var id: UInt32
    var pid: pid_t
    var bundleID: String
    var appName: String
    var title: String
    var frame: CGRect
    var spaceIDs: [UInt64]
}
