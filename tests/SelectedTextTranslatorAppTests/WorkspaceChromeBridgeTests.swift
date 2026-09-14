import Foundation
import Testing
@testable import SelectedTextTranslatorApp

/// 用隔离的安装记录与真实进程心跳复现令牌变化，不启动 Chrome 或修改用户场景。
@MainActor
struct WorkspaceChromeBridgeTests {
    private let saved = "00000000-0000-0000-0000-000000000001"
    private let replacement = "00000000-0000-0000-0000-000000000002"
    private let other = "00000000-0000-0000-0000-000000000003"

    /// 原令牌仍在线时身份明确，其他资料同时连接也不能抢走恢复目标。
    @Test func originalConnectionWins() throws {
        try withBridge(installed: ["Default", "Profile 1"], connected: [saved, other]) { bridge in
            let profile = try bridge.restorationProfile(savedProfile: saved, profileDirectory: "Default")
            #expect(profile == saved)
        }
    }

    /// 复现已保存令牌失效、同一资料扩展生成新令牌的实际故障。
    @Test func replacementConnectionInSameDirectoryIsAccepted() throws {
        try withBridge(installed: ["Default"], connected: [replacement]) { bridge in
            let profile = try bridge.restorationProfile(savedProfile: saved, profileDirectory: "Default")
            #expect(profile == replacement)
        }
    }

    /// 唯一在线连接也可能来自另一资料，必须核对安装目录。
    @Test func differentDirectoryIsRejected() throws {
        try withBridge(installed: ["Profile 1"], connected: [replacement]) { bridge in
            #expect(throws: WorkspaceError.self) { try bridge.restorationProfile(savedProfile: saved, profileDirectory: "Default") }
        }
    }

    /// 多个新连接无法映射到原资料时，立即报错而不按遍历顺序猜测。
    @Test func ambiguousConnectionsAreRejected() throws {
        try withBridge(installed: ["Default"], connected: [replacement, other]) { bridge in
            #expect(throws: WorkspaceError.self) { try bridge.restorationProfile(savedProfile: saved, profileDirectory: "Default") }
        }
    }

    /// 缺少或存在多份安装记录时，即使只有一个在线连接也不足以确认资料归属。
    @Test(arguments: [[], ["Default", "Profile 1"]])
    func unprovenInstallationIsRejected(installed: [String]) throws {
        try withBridge(installed: installed, connected: [replacement]) { bridge in
            #expect(throws: WorkspaceError.self) { try bridge.restorationProfile(savedProfile: saved, profileDirectory: "Default") }
        }
    }

    /// 浏览器尚未启动时保持待连接，启动后新令牌可以通过相同解析入口恢复。
    @Test func disconnectedProfileRemainsPending() throws {
        try withBridge(installed: ["Default"], connected: []) { bridge in
            let profile = try bridge.restorationProfile(savedProfile: saved, profileDirectory: "Default")
            #expect(profile == nil)
        }
    }

    /// 临时文件仅模拟 Native Messaging 心跳和扩展安装项；始终清理且不访问默认用户目录。
    private func withBridge(installed: [String], connected: [String], check: (WorkspaceChromeBridge) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chromeRoot = root.appendingPathComponent("Chrome")
        let bridgeRoot = root.appendingPathComponent("bridge")
        for directory in installed {
            let profile = chromeRoot.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            let settings = ["extensions": ["settings": ["ldacmagnlnmafacmmfgaeclcllokfjeb": ["state": 1]]]]
            try JSONSerialization.data(withJSONObject: settings).write(to: profile.appendingPathComponent("Secure Preferences"))
        }
        for token in connected {
            let directory = bridgeRoot.appendingPathComponent(token)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let status: [String: Any] = ["protocolVersion": 1, "updatedAt": Date().timeIntervalSince1970,
                                         "pid": ProcessInfo.processInfo.processIdentifier]
            try JSONSerialization.data(withJSONObject: status).write(to: directory.appendingPathComponent("status.json"))
        }
        try check(WorkspaceChromeBridge(root: bridgeRoot, chromeRoot: chromeRoot))
    }
}
