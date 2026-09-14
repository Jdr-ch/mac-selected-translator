import Foundation
import CoreGraphics

/// 场景仅包含用户选择的桌面及窗口；Chrome 运行时编号不能作为跨重启身份。
struct WorkspaceScene: Codable {
    var version = 1
    var savedAt = Date()
    var profileToken: String
    var chromeProfileDirectory: String
    var windows: [WorkspaceWindow]
    /// 新场景显式记录空桌面；旧版没有此字段时，从窗口中恢复桌面清单。
    var desktops: [WorkspaceDesktop]? = nil

    var savedDesktops: [WorkspaceDesktop] {
        var seen: Set<String> = []
        return ((desktops ?? []) + windows.map(\.desktop)).filter { seen.insert($0.selectionKey).inserted }
            .sorted { $0.ordinal < $1.ordinal }
    }
}

/// 按显示器与“桌面 N”绑定；系统 UUID 和 Space ID 仅描述采集时的实际空间。
struct WorkspaceDesktop: Codable, Equatable, Identifiable {
    var id: String
    var displayID: String
    var ordinal: Int
    var spaceID: UInt64
    var screenFrame: CGRect
    var label: String { "桌面 \(ordinal)" }
    var selectionKey: String { "\(displayID)#\(ordinal)" }
}

/// 窗口位置相对屏幕可用区域保存，同一分辨率精确还原，变化时按比例适配。
struct WorkspaceWindow: Codable, Identifiable {
    var id = UUID().uuidString
    var bundleID: String
    var appName: String
    var title: String
    var desktop: WorkspaceDesktop
    var relativeFrame: CGRect
    var projectPath: String?
    var chrome: ChromeWindowSnapshot?
    var issues: [String] = []

    /// 预览中的业务标签由项目或群组组成，避免展示不稳定的网页标题作为身份。
    var label: String {
        if let projectPath { return "\(appName) · \(URL(fileURLWithPath: projectPath).lastPathComponent)" }
        if let chrome {
            let groups = chrome.groups.map(\.title).joined(separator: "、")
            return "Chrome · \(groups.isEmpty ? title : groups)（\(chrome.tabs.count) 个标签页）"
        }
        return "\(appName) · \(title)"
    }
}

/// 字段对应扩展协议 v1；groupId 为 -1 表示未分组，编号只在本次快照内关联。
struct ChromeTabSnapshot: Codable, Equatable {
    var id: Int?
    var url: String
    var title: String
    var pinned: Bool
    var active: Bool
    var groupId: Int
}

/// saved 标记由原生 Chrome 工具栏验证，避免重建已保存群组造成重复。
struct ChromeGroupSnapshot: Codable, Equatable {
    var id: Int
    var title: String
    var color: String
    var collapsed: Bool
    var saved: Bool?
}

struct ChromeWindowSnapshot: Codable {
    var windowId: Int
    var left: Double
    var top: Double
    var width: Double
    var height: Double
    var state: String
    var tabs: [ChromeTabSnapshot]
    var groups: [ChromeGroupSnapshot]
    var frame: CGRect { CGRect(x: left, y: top, width: width, height: height) }
    var activeTitle: String { tabs.first(where: \.active)?.title ?? "" }
}

/// 失败列表按条目保留，重试只执行失败项；结果不等同于窗口已成功定位。
struct WorkspaceOutcome {
    var windowID: String
    var label: String
    var error: String?
    /// 恢复成功后的实际系统窗口编号，仅供本次面板会话的桌面对齐使用，不写入场景模板。
    var nativeWindowID: UInt32? = nil
}

enum WorkspaceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// 纯几何和绑定规则与系统写操作分离，便于覆盖显示器变化和桌面缺失。
enum WorkspaceGeometry {
    static func relative(_ frame: CGRect, in screen: CGRect) -> CGRect {
        CGRect(x: (frame.minX - screen.minX) / screen.width,
               y: (frame.minY - screen.minY) / screen.height,
               width: frame.width / screen.width, height: frame.height / screen.height)
    }

    static func absolute(_ frame: CGRect, in screen: CGRect) -> CGRect {
        let width = min(max(frame.width * screen.width, 100), screen.width)
        let height = min(max(frame.height * screen.height, 100), screen.height)
        return CGRect(x: min(max(screen.minX + frame.minX * screen.width, screen.minX), screen.maxX - width),
                      y: min(max(screen.minY + frame.minY * screen.height, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }

    static func resolve(_ saved: WorkspaceDesktop, in desktops: [WorkspaceDesktop]) throws -> WorkspaceDesktop {
        guard let desktop = desktops.first(where: { $0.selectionKey == saved.selectionKey }) else {
            throw WorkspaceError.message("未找到原显示器上的\(saved.label)，请重新绑定桌面。")
        }
        return desktop
    }
}

/// 场景使用原子写入；损坏或不支持的版本显式报错，不以空场景覆盖旧数据。
final class WorkspaceSceneStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SelectedTextTranslator/WorkspaceScene")
    let file: URL

    init(file: URL = WorkspaceSceneStore.directory.appendingPathComponent("scene.json")) { self.file = file }

    func load() throws -> WorkspaceScene? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let scene = try JSONDecoder().decode(WorkspaceScene.self, from: Data(contentsOf: file))
        guard scene.version == 1 else { throw WorkspaceError.message("场景版本不受支持，请更新 App。") }
        return scene
    }

    func save(_ scene: WorkspaceScene) throws {
        guard !scene.savedDesktops.isEmpty, scene.windows.allSatisfy({ $0.issues.isEmpty }) else {
            throw WorkspaceError.message("请先补全待处理条目，再保存工作场景。")
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(scene).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
