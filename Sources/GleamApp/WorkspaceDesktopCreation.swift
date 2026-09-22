import AppKit
import ApplicationServices
import Darwin

/// 通过 Dock 的调度中心“添加桌面”按钮创建普通桌面，不猜测私有 Space 创建接口的参数。
/// AX 标识与通知签名参考 Hammerspoon extensions/spaces/{spaces.lua,private.h}。
@MainActor
final class WorkspaceDesktopCreation {
    private typealias DockNotification = @convention(c) (CFString, Int32) -> Int32
    private let desktop: WorkspaceNativeDesktop
    /// 只关闭本次恢复打开的调度中心；用户原本打开的调度中心保持原状。
    private var openedMissionControl = false

    init(desktop: WorkspaceNativeDesktop) { self.desktop = desktop }

    /// 每次添加后等到 WindowServer 出现一个新桌面才返回，避免重复点击造成多建。
    func add(on displayID: String) async throws {
        guard AXIsProcessTrusted() else { throw WorkspaceError.message("创建桌面需要本 App 的辅助功能权限。") }
        guard let number = displayNumber(displayID) else { throw WorkspaceError.message("目标显示器已断开，请重新绑定桌面。") }
        let before = Set(try desktop.desktops().filter { $0.displayID == displayID }.map(\.spaceID))
        if missionControl() == nil {
            try toggleMissionControl()
            openedMissionControl = true
        }
        let deadline = Date().addingTimeInterval(4)
        var button: AXUIElement?
        while Date() < deadline {
            if let mc = missionControl(), let display = children(mc).first(where: {
                identifier($0) == "mc.display" && (WorkspaceWindowCatalog.read($0, "AXDisplayID") as NSNumber?)?.uint32Value == number
            }), let spaces = children(display).first(where: { identifier($0) == "mc.spaces" }) {
                button = children(spaces).first(where: { identifier($0) == "mc.spaces.add" })
            }
            if button != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let button, AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
            throw WorkspaceError.message("未能点击目标显示器的“添加桌面”，请在调度中心手动新建后重试。")
        }
        for _ in 0..<50 {
            let after = Set(try desktop.desktops().filter { $0.displayID == displayID }.map(\.spaceID))
            if after.count == before.count + 1, before.isSubset(of: after) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw WorkspaceError.message("等待新桌面出现超时，请检查调度中心后重试。")
    }

    /// 桌面准备结束后收起由本流程打开的调度中心，再开始窗口定位。
    func finish() async {
        guard openedMissionControl else { return }
        openedMissionControl = false
        guard missionControl() != nil else { return }
        try? toggleMissionControl()
        for _ in 0..<20 {
            if missionControl() == nil { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// 通知的 ABI 为 CGError(CFStringRef, int)，缺失符号时给出可操作的手动替代入口。
    private func toggleMissionControl() throws {
        let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
        guard let handle = dlopen(path, RTLD_LAZY) else { throw WorkspaceError.message("无法打开调度中心，请手动新建缺失桌面。") }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "CoreDockSendNotification") else {
            throw WorkspaceError.message("当前系统不支持自动打开调度中心，请手动新建缺失桌面。")
        }
        let notify = unsafeBitCast(symbol, to: DockNotification.self)
        guard notify("com.apple.expose.awake" as CFString, 0) == 0 else {
            throw WorkspaceError.message("系统拒绝打开调度中心，请手动新建缺失桌面。")
        }
    }

    private func missionControl() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        return children(AXUIElementCreateApplication(dock.processIdentifier)).first { identifier($0) == "mc" }
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        WorkspaceWindowCatalog.read(element, kAXChildrenAttribute) ?? []
    }

    private func identifier(_ element: AXUIElement) -> String {
        WorkspaceWindowCatalog.read(element, "AXIdentifier") ?? ""
    }

    private func displayNumber(_ identifier: String) -> UInt32? {
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { continue }
            if CFUUIDCreateString(nil, uuid) as String == identifier { return number }
        }
        return nil
    }
}
