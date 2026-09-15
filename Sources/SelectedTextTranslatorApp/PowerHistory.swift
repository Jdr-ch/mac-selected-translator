import Foundation

/// 记录系统输入功率的时间序列；仅保留最近两小时，避免长期运行无限增长。
struct PowerHistorySample: Equatable, Sendable {
    let date: Date
    let watts: Double
}

struct PowerHistory: Equatable, Sendable {
    static let window: TimeInterval = 2 * 60 * 60
    static let minimumSpacing: TimeInterval = 5
    static let maximumSamples = 1441

    private(set) var samples: [PowerHistorySample] = []

    /// 每 5 秒最多保留一个点；同一时间桶用最新读数替换，绘图不会被 1 Hz 面板刷新放大。
    @discardableResult
    mutating func append(watts: Double, at date: Date) -> Bool {
        guard watts.isFinite, watts >= 0 else { return false }
        if let last = samples.last {
            guard date >= last.date else { return false }
            if date.timeIntervalSince(last.date) < Self.minimumSpacing {
                samples[samples.count - 1] = PowerHistorySample(date: date, watts: watts)
                trim(around: date)
                return true
            }
        }
        samples.append(PowerHistorySample(date: date, watts: watts))
        trim(around: date)
        return true
    }

    /// 测试和视图更新可用当前时间裁剪一次，确保暂停期间也不会展示过期点。
    mutating func trim(around date: Date) {
        let cutoff = date.addingTimeInterval(-Self.window)
        samples.removeAll { $0.date < cutoff }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }
}
