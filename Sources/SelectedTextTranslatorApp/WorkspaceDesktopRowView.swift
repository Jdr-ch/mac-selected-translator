import AppKit
import QuartzCore

/// 桌面行背景的循环光带只表示正在运行；由 Core Animation 驱动，无进度计时器。
@MainActor
final class WorkspaceDesktopRowView: NSView {
    private let sweep = CAGradientLayer()
    private var running = false
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(sweep)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateAnimation() } })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.updateAnimation() } })
    }

    required init?(coder: NSCoder) { fatalError("不使用归档初始化") }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }

    /// 行复用时同步运行状态；结束或隐藏窗口后立即移除动画，减少后台绘制。
    func configure(running: Bool) {
        self.running = running
        updateAnimation()
    }

    override func layout() { super.layout(); updateAnimation() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateAnimation() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateAnimation() }

    private func updateAnimation() {
        let visible = running && window?.occlusionState.contains(.visible) == true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.isHidden = !running
        sweep.frame = CGRect(x: -bounds.width * 0.45, y: 0, width: bounds.width * 0.45, height: bounds.height)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = WorkspaceScenePalette.accent
            layer?.backgroundColor = (running ? color.blended(withFraction: 0.96, of: WorkspaceScenePalette.content) ?? WorkspaceScenePalette.content
                : WorkspaceScenePalette.content).cgColor
            layer?.borderColor = WorkspaceScenePalette.line.cgColor
            sweep.colors = [color.withAlphaComponent(0).cgColor, color.withAlphaComponent(0.16).cgColor, color.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
        // 减少动态效果时显示静态浅色提示，仍保留行内的运行阶段文字。
        if !visible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            sweep.removeAnimation(forKey: "workspace-running")
            if running { sweep.position.x = bounds.midX }
            return
        }
        guard sweep.animation(forKey: "workspace-running") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = bounds.width * 1.5
        animation.duration = 2.6
        animation.repeatCount = .infinity
        sweep.add(animation, forKey: "workspace-running")
    }
}
