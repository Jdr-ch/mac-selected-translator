import Foundation

/// 电量与充电状态来自同一次采集；缺失电量保留为空，不补成 0%。
struct BatteryHistorySample: Equatable, Sendable {
    let date: Date
    let percent: Double?
    let state: PowerState
    /// 暂停恢复后的首点不与暂停前连线，也不推断间隔内的充电状态。
    var startsNewSegment = false
}

/// 与功率历史共享两小时时窗，独立保存拔电后的电量和状态，不增加硬件查询。
struct BatteryHistory: Equatable, Sendable {
    static let window = PowerHistory.window
    static let minimumSpacing = PowerHistory.minimumSpacing
    /// 常规后台采样为 15 秒；超过三个周期视为缺测，不跨越空档绘图。
    static let maximumGap: TimeInterval = 45
    static let maximumSamples = PowerHistory.maximumSamples * 2

    private(set) var samples: [BatteryHistorySample] = []
    /// 暂停时置位，恢复后的首次有效时间采样消费该标记。
    private var continuityBroken = false

    /// 每五秒记录电量，状态变化立即保留；以已保留点节流，避免 1 Hz 刷新永远覆盖同一点。
    @discardableResult
    mutating func append(snapshot: PowerSnapshot, at date: Date) -> Bool {
        if let last = samples.last, date < last.date { return false }
        let previousCount = samples.count
        samples.removeAll { $0.date < date.addingTimeInterval(-Self.window) }
        let percent = snapshot.batteryPercent.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        if let last = samples.last, !continuityBroken,
           date.timeIntervalSince(last.date) < Self.minimumSpacing,
           last.state == snapshot.state, (last.percent == nil) == (percent == nil) {
            return samples.count != previousCount
        }
        let startsNewSegment = continuityBroken
            || samples.last.map { date.timeIntervalSince($0.date) > Self.maximumGap } == true
        samples.append(BatteryHistorySample(date: date, percent: percent, state: snapshot.state,
                                            startsNewSegment: startsNewSegment))
        continuityBroken = false
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
        return true
    }

    /// 由监控生命周期显式打断连续性，短暂锁屏也不能被当作持续充电的证据。
    mutating func breakContinuity() {
        continuityBroken = true
    }

    /// 状态从采样时间生效到下一次观测；仅合并连续且已观测到的充电区间。
    static func chargingIntervals(in samples: [BatteryHistorySample]) -> [DateInterval] {
        var intervals: [DateInterval] = []
        for (previous, next) in zip(samples, samples.dropFirst()) {
            let duration = next.date.timeIntervalSince(previous.date)
            guard previous.state == .charging, !next.startsNewSegment,
                  duration > 0, duration <= maximumGap else { continue }
            if let last = intervals.last, last.end == previous.date {
                intervals[intervals.count - 1] = DateInterval(start: last.start, end: next.date)
            } else {
                intervals.append(DateInterval(start: previous.date, end: next.date))
            }
        }
        return intervals
    }
}
