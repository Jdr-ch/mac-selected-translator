import Foundation

/// 两种指标共用浮层和绘图交互；百分比与瓦特各自保留单位、范围和摘要。
enum PowerHistoryMetric {
    case systemInput, battery
}

/// 图表只消费展示点；电池点额外携带状态和断点，供底纹与悬停说明使用。
struct PowerHistoryChartPoint {
    let date: Date
    let value: Double?
    var state: PowerState?
    var startsNewSegment = false
}

/// 集中转换共享快照历史，避免视图混淆电量、系统输入功率与实际充电状态。
struct PowerHistoryChartData {
    let metric: PowerHistoryMetric
    let points: [PowerHistoryChartPoint]
    var chargingIntervals: [DateInterval] = []
    let summary: String

    var title: String { metric == .battery ? "最近两小时电量与充电时段" : "最近两小时系统输入功率" }
    var unit: String { metric == .battery ? "%" : " W" }

    /// 功率沿用最多 240 个绘制点；保留真实时间坐标，不按索引压缩采样间隔。
    static func systemInput(_ samples: [PowerHistorySample]) -> PowerHistoryChartData {
        let display: [PowerHistorySample]
        if samples.count > 240 {
            let step = Double(samples.count - 1) / 239
            display = (0..<240).map { samples[Int((Double($0) * step).rounded())] }
        } else {
            display = samples
        }
        // 摘要仍使用完整样本，降采样仅影响折线，不能漏算峰值或改变平均功率。
        let values = samples.map(\.watts)
        let summary: String
        if let latest = values.last, let maximum = values.max() {
            let average = values.reduce(0, +) / Double(values.count)
            summary = String(format: "当前 %.1f W · 最高 %.1f W · 平均 %.1f W", latest, maximum, average)
        } else {
            summary = "暂无最近两小时数据"
        }
        return PowerHistoryChartData(metric: .systemInput,
                                     points: display.map { PowerHistoryChartPoint(date: $0.date, value: $0.watts) },
                                     summary: summary)
    }

    /// 电池状态转折不降采样，避免短充电区间在折线抽点时消失。
    static func battery(_ samples: [BatteryHistorySample]) -> PowerHistoryChartData {
        let percent = samples.last?.percent.map { String(format: "%.0f%%", $0) } ?? "—"
        let summary = samples.isEmpty ? "暂无最近两小时数据" : "当前 \(percent) · 绿色区域为充电时段"
        return PowerHistoryChartData(metric: .battery, points: samples.map {
            PowerHistoryChartPoint(date: $0.date, value: $0.percent, state: $0.state,
                                   startsNewSegment: $0.startsNewSegment)
        }, chargingIntervals: BatteryHistory.chargingIntervals(in: samples), summary: summary)
    }
}
