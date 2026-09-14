import AppKit
import ApplicationServices
import Darwin
import WorkspaceSkyLightBridge

/// 将非公开 Spaces 接口集中在此适配层；窗口归属和每次写入均回读，不按桌面编号猜测。
@MainActor
final class WorkspaceNativeDesktop {
    private typealias Connection = @convention(c) () -> Int32
    private typealias CopyDisplays = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetCompat = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SetWorkspace = @convention(c) (Int32, UnsafePointer<UInt32>, Int32, Int32) -> Int32
    private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    /// 系统升级缺失接口时停止当前条目，禁止静默退化成移动到其他桌面。
    private func symbol<T>(_ name: String, from handle: UnsafeMutableRawPointer?, as type: T.Type) throws -> T {
        guard let handle, let pointer = dlsym(handle, name) else {
            throw WorkspaceError.message("当前 macOS 缺少桌面控制接口 \(name)，需要适配此系统版本。")
        }
        return unsafeBitCast(pointer, to: type)
    }

    /// 从当前系统拓扑读取普通桌面，保留稳定 UUID；全屏空间不计入桌面编号。
    func desktops() throws -> [WorkspaceDesktop] {
        let connection = try symbol("SLSMainConnectionID", from: sky, as: Connection.self)()
        let copy = try symbol("SLSCopyManagedDisplaySpaces", from: sky, as: CopyDisplays.self)
        guard let displays = copy(connection)?.takeRetainedValue() as? [[String: Any]] else {
            throw WorkspaceError.message("无法读取当前虚拟桌面。")
        }
        var result: [WorkspaceDesktop] = []
        for display in displays {
            guard let identifier = display["Display Identifier"] as? String,
                  let screen = NSScreen.screens.first(where: { screenIdentifier($0) == identifier || (identifier == "Main" && $0 == NSScreen.screens.first) }),
                  let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces where space["type"] as? Int == 0 {
                guard let id = space["uuid"] as? String, let number = space["ManagedSpaceID"] as? NSNumber else { continue }
                result.append(WorkspaceDesktop(id: id, displayID: screenIdentifier(screen), ordinal: result.count + 1,
                                               spaceID: number.uint64Value, screenFrame: screenFrame(screen)))
            }
        }
        return result
    }

    /// 实际窗口所属的空间来自 WindowServer；同坐标、同应用的跨桌面窗口也可区分。
    func spaces(for windowID: UInt32) throws -> [UInt64] {
        let connection = try symbol("SLSMainConnectionID", from: sky, as: Connection.self)()
        let copy = try symbol("SLSCopySpacesForWindows", from: sky, as: CopySpaces.self)
        return (copy(connection, 7, [NSNumber(value: windowID)] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.uint64Value)
    }

    /// 优先采用 Tahoe 的跨应用异步移动；只有接口缺失时使用旧兼容映射，最终以实际桌面为准。
    func move(_ windowID: UInt32, to desktop: WorkspaceDesktop) async throws {
        if try spaces(for: windowID) == [desktop.spaceID] { return }
        let submitted = WorkspaceSubmitBridgedMove(windowID, desktop.spaceID)
        guard submitted >= 0 else { throw WorkspaceError.message("macOS 无法创建跨桌面移动操作，请重试。") }
        var legacyResult: Int32?
        if submitted == 0 {
            let connection = try symbol("SLSMainConnectionID", from: sky, as: Connection.self)()
            let compat = try symbol("SLSSpaceSetCompatID", from: sky, as: SetCompat.self)
            let move = try symbol("SLSSetWindowListWorkspace", from: sky, as: SetWorkspace.self)
            let marker: Int32 = 0x79616265
            compat(connection, desktop.spaceID, marker)
            var id = windowID
            legacyResult = move(connection, &id, 1, marker)
            compat(connection, desktop.spaceID, 0)
        }
        // 操作是异步提交；系统动画期间继续观察，不能把提交回执当成移动成功。
        for _ in 0..<50 {
            if try spaces(for: windowID) == [desktop.spaceID] { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let detail = legacyResult.map { "旧接口返回码 \($0)" } ?? "异步移动未完成"
        throw WorkspaceError.message("macOS 未完成移动到\(desktop.label)（\(detail)）。")
    }

    /// AX 到原生窗口编号直接映射，避免复用旧整理功能中只适用于当前桌面的几何配对。
    func id(of element: AXUIElement) throws -> UInt32 {
        try WorkspaceWindowDiscovery.windowID(element)
    }

    private func screenIdentifier(_ screen: NSScreen) -> String {
        guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private func screenFrame(_ screen: NSScreen) -> CGRect {
        let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let frame = screen.visibleFrame
        return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
    }
}

/// 原生窗口对象只在当前进程生命周期内使用，持久化场景中不保存 AX 引用。
struct WorkspaceNativeWindow {
    var id: UInt32
    var element: AXUIElement
    var bundleID: String
    var appName: String
    var title: String
    var frame: CGRect
    var spaceIDs: [UInt64]
}

/// 采集和定位完整桌面窗口；与旧的“整理／对齐”控制器各自维护行为边界。
@MainActor
final class WorkspaceWindowCatalog {
    let desktop = WorkspaceNativeDesktop()
    private let discovery = WorkspaceWindowDiscovery()
    private(set) var unresolved: [WorkspaceWindowSurface] = []

    /// WindowServer 的全部桌面是采集来源；AX 只负责读取窗口属性，不能决定窗口是否存在。
    func windows(bundleID: String? = nil, in targetSpaces: Set<UInt64>? = nil) async throws -> [WorkspaceNativeWindow] {
        guard AXIsProcessTrusted() else { throw WorkspaceError.message("请在系统设置中为本 App 开启辅助功能权限。") }
        unresolved = []
        let surfaces = try windowSurfaces(bundleID: bundleID, in: targetSpaces)
        let requested = Dictionary(grouping: surfaces, by: \.pid).mapValues { Set($0.map(\.id)) }
        let resolved = try await discovery.resolve(requested)
        unresolved = surfaces.filter { resolved.missing.contains($0.id) }
        var result: [WorkspaceNativeWindow] = []
        for surface in surfaces {
            guard let element = resolved.elements[surface.id] else { continue }
            guard let subrole: String = Self.read(element, kAXSubroleAttribute) else {
                unresolved.append(surface)
                continue
            }
            guard subrole == kAXStandardWindowSubrole,
                      Self.read(element, kAXMinimizedAttribute) as Bool? != true,
                      Self.read(element, "AXFullScreen") as Bool? != true else { continue }
            guard let frame = Self.frame(element) else { unresolved.append(surface); continue }
            result.append(WorkspaceNativeWindow(id: surface.id, element: element, bundleID: surface.bundleID,
                appName: surface.appName, title: Self.read(element, kAXTitleAttribute) ?? surface.title,
                frame: frame, spaceIDs: surface.spaceIDs))
        }
        return result
    }

    /// 排除无桌面归属的系统辅助窗口；可限定目标桌面或应用，避免恢复单项时扫描无关进程。
    func windowSurfaces(bundleID: String? = nil, in targetSpaces: Set<UInt64>? = nil) throws -> [WorkspaceWindowSurface] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isHidden && $0.processIdentifier != getpid()
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier && (bundleID == nil || $0.bundleIdentifier == bundleID)
        }
        let byPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.processIdentifier, $0) })
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw WorkspaceError.message("无法读取全部桌面的窗口清单，请重试。")
        }
        return try rows.compactMap { row in
            guard row[kCGWindowLayer as String] as? Int == 0,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32, let app = byPID[pid],
                  let bundleID = app.bundleIdentifier,
                  let number = row[kCGWindowNumber as String] as? NSNumber,
                  let bounds = row[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame.width > 0, frame.height > 0 else { return nil }
            let spaces = try desktop.spaces(for: number.uint32Value)
            guard !spaces.isEmpty, targetSpaces == nil || !targetSpaces!.isDisjoint(with: spaces) else { return nil }
            return WorkspaceWindowSurface(id: number.uint32Value, pid: pid, bundleID: bundleID,
                appName: app.localizedName ?? bundleID, title: row[kCGWindowName as String] as? String ?? "未读取窗口标题",
                frame: frame, spaceIDs: spaces)
        }
    }

    /// 浏览器 API 编号与原生窗口编号并不相同；标题与实时位置必须能唯一关联。
    func chromeWindow(_ snapshot: ChromeWindowSnapshot, among windows: [WorkspaceNativeWindow]) throws -> WorkspaceNativeWindow {
        let chrome = windows.filter { $0.bundleID == "com.google.Chrome" }
        let titled = chrome.filter { !$0.title.isEmpty && !snapshot.activeTitle.isEmpty && $0.title.hasPrefix(snapshot.activeTitle) }
        let located = titled.filter { Self.distance($0.frame, snapshot.frame) < 32 }
        if located.count == 1 { return located[0] }
        if titled.count == 1 { return titled[0] }
        throw WorkspaceError.message("Chrome 窗口“\(snapshot.activeTitle)”无法唯一匹配，请保持窗口打开后重试。")
    }

    /// WebStorm 项目按钮暴露真实目录；仅以近期项目元数据补齐完全相同的实时窗口标题。
    func projectPath(for window: WorkspaceNativeWindow) -> String? {
        let candidates = Self.descendants(window.element, maxDepth: 8).compactMap { element -> String? in
            let description: String = Self.read(element, kAXDescriptionAttribute) ?? ""
            guard description.hasPrefix("项目:") || description.hasPrefix("Project:") else { return nil }
            let help: String = Self.read(element, kAXHelpAttribute) ?? ""
            let path = (help as NSString).expandingTildeInPath
            return FileManager.default.fileExists(atPath: path) ? path : nil
        }
        if Set(candidates).count == 1 { return candidates[0] }
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/JetBrains")
        let versions = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        var paths: Set<String> = []
        for version in versions where version.lastPathComponent.hasPrefix("WebStorm") {
            guard let xml = try? XMLDocument(contentsOf: version.appendingPathComponent("options/recentProjects.xml")),
                  let entries = try? xml.nodes(forXPath: "//entry") else { continue }
            for case let entry as XMLElement in entries {
                guard let meta = try? entry.nodes(forXPath: "value/RecentProjectMetaInfo").first as? XMLElement,
                      meta.attribute(forName: "frameTitle")?.stringValue == window.title,
                      let rawPath = entry.attribute(forName: "key")?.stringValue else { continue }
                let path = rawPath.replacingOccurrences(of: "$USER_HOME$", with: FileManager.default.homeDirectoryForCurrentUser.path)
                if FileManager.default.fileExists(atPath: path) { paths.insert(path) }
            }
        }
        return paths.count == 1 ? paths.first : nil
    }

    /// Chrome 保存群组入口来自原生工具栏，跳过网页区域，避免将网页文字误当系统按钮。
    func savedGroupButton(_ name: String, windows: [WorkspaceNativeWindow]) -> AXUIElement? {
        for window in windows where window.bundleID == "com.google.Chrome" {
            for element in Self.descendants(window.element, maxDepth: 9) {
                let text = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                    .compactMap { Self.read(element, $0) as String? }.joined(separator: " ")
                if text.contains("“\(name)”分组") || text.contains("\"\(name)\" group") {
                    return element
                }
            }
        }
        return nil
    }

    /// 尺寸不允许修改的 App 仍可恢复位置，随后回读并报告无法精确恢复的尺寸。
    func applyFrame(_ frame: CGRect, to window: WorkspaceNativeWindow) throws {
        var settable = DarwinBoolean(false)
        let resize = AXUIElementIsAttributeSettable(window.element, kAXSizeAttribute as CFString, &settable) == .success && settable.boolValue
        for mutation in WindowLayoutPlanner.geometryMutations(for: frame, resizesWindow: resize) {
            let error: AXError
            switch mutation {
            case .position(var point):
                guard let value = AXValueCreate(.cgPoint, &point) else { continue }
                error = AXUIElementSetAttributeValue(window.element, kAXPositionAttribute as CFString, value)
            case .size(var size):
                guard let value = AXValueCreate(.cgSize, &size) else { continue }
                error = AXUIElementSetAttributeValue(window.element, kAXSizeAttribute as CFString, value)
            }
            guard error == .success else { throw WorkspaceError.message("\(window.appName)拒绝调整窗口位置或大小。") }
        }
    }

    static func distance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        abs(left.minX - right.minX) + abs(left.minY - right.minY) + abs(left.width - right.width) + abs(left.height - right.height)
    }

    static func read<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position: AXValue = read(element, kAXPositionAttribute), let size: AXValue = read(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    /// 遍历预算限制在窗口框架内，避免读取 WebStorm 编辑器全文或 Chrome 页面内容。
    static func descendants(_ root: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        while cursor < queue.count && result.count < 1200 {
            let (element, depth) = queue[cursor]
            cursor += 1
            let role: String = read(element, kAXRoleAttribute) ?? ""
            if ["AXWebArea", "AXTextArea", "AXOutline"].contains(role) { continue }
            result.append(element)
            if depth < maxDepth {
                queue.append(contentsOf: (read(element, kAXChildrenAttribute) as [AXUIElement]? ?? []).map { ($0, depth + 1) })
            }
        }
        return result
    }
}
