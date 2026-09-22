import Foundation
import IOKit
import IOKit.ps

/// 接电与充电分别判断；未知值不会被解释为电池正在放电。
enum PowerState: String, Sendable {
    case charging, externalPower, battery, unavailable

    var title: String {
        switch self {
        case .charging: return "正在充电"
        case .externalPower: return "接电未充电"
        case .battery: return "使用电池"
        case .unavailable: return "电源状态暂不可用"
        }
    }
}

/// 功率开关独立持久化；旧版功率／电流选择不影响新版默认开启行为。
enum PowerDisplayPreference {
    static let defaultsKey = "powerMonitor.showPower"

    /// 首次使用默认勾选，已保存的关闭选择在下次启动时继续生效。
    static func isPowerShown(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// 同次原生采集的电源快照；电气值统一为 V/A/W，缺失数据保持 nil。
struct PowerSnapshot: Equatable, Sendable {
    var state: PowerState = .unavailable
    var externalConnected: Bool?
    var batteryPercent: Double?
    var adapterName: String?
    var adapterWatts: Double?
    var adapterVoltage: Double?
    var adapterCurrent: Double?
    var inputVoltage: Double?
    var inputWatts: Double?
    var batteryVoltage: Double?
    /// 正值表示充入电池，负值表示电池放电；不对放电值取绝对值。
    var batteryCurrent: Double?

    /// 使用电池包电压与同次平均电流估算，绝不借用整机输入功率或适配器档位电流。
    var estimatedChargingWatts: Double? {
        guard state == .charging, let voltage = batteryVoltage,
              let current = batteryCurrent, current >= 0 else { return nil }
        return voltage * current
    }

    /// 根据已确认字段转换快照，拔电时即使驱动仍缓存旧适配器字典也不展示它。
    static func decode(registry: [String: Any], source: [String: Any]) -> PowerSnapshot {
        var result = PowerSnapshot()
        let publicState = source[kIOPSPowerSourceStateKey] as? String
        // IORegistry 的连接位表示物理接电；IOPS 在扩展字段不可用时提供基础供电状态。
        result.externalConnected = (registry["ExternalConnected"] as? NSNumber)?.boolValue
        if result.externalConnected == nil {
            if publicState == kIOPSACPowerValue { result.externalConnected = true }
            if publicState == kIOPSBatteryPowerValue { result.externalConnected = false }
        }
        let charging = (source[kIOPSIsChargingKey] as? NSNumber)?.boolValue
            ?? (registry["IsCharging"] as? NSNumber)?.boolValue
        if result.externalConnected == false {
            result.state = .battery
        } else if result.externalConnected == true, let charging {
            result.state = charging ? .charging : .externalPower
        }
        if let current = finiteNumber(source[kIOPSCurrentCapacityKey]),
           let maximum = finiteNumber(source[kIOPSMaxCapacityKey]), maximum > 0 {
            let percent = current / maximum * 100
            if (0...100).contains(percent) { result.batteryPercent = percent }
        } else if let percent = finiteNumber(registry["CurrentCapacity"]), (0...100).contains(percent) {
            // AppleSmartBattery 的公开容量为百分比；原始 mAh 字段不参与此回退。
            result.batteryPercent = percent
        }
        result.batteryVoltage = positiveMilliValue(registry["Voltage"])
        result.batteryCurrent = signedMilliamps(registry["Amperage"]).map { $0 / 1000 }
        if result.externalConnected == true {
            let adapter = registry["AdapterDetails"] as? [String: Any] ?? [:]
            let telemetry = registry["PowerTelemetryData"] as? [String: Any] ?? [:]
            if let name = adapter["Name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                result.adapterName = name
            }
            result.adapterWatts = positiveNumber(adapter["Watts"])
            result.adapterVoltage = positiveMilliValue(adapter["AdapterVoltage"])
            result.adapterCurrent = positiveMilliValue(adapter["Current"])
            result.inputVoltage = positiveMilliValue(telemetry["SystemVoltageIn"])
            if let milliwatts = finiteNumber(telemetry["SystemPowerIn"]), milliwatts >= 0 {
                result.inputWatts = milliwatts / 1000
            }
        }
        return result
    }

    /// 某些驱动把 32/64 位负电流作为无符号 NSNumber 导出；恢复补码后再进行单位换算。
    static func signedMilliamps(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, number.doubleValue.isFinite,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let signed = number.int64Value
        if signed > Int64(Int32.max), signed <= Int64(UInt32.max) {
            return Double(Int32(bitPattern: UInt32(signed)))
        }
        return Double(signed)
    }

    /// 数字输入不接受布尔、字符串或非有限值，避免缺失状态被误转为测量数值。
    private static func finiteNumber(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// 电压、适配器额定能力必须为正；驱动未提供的零占位不作为有效读数。
    private static func positiveNumber(_ raw: Any?) -> Double? {
        guard let value = finiteNumber(raw), value > 0 else { return nil }
        return value
    }

    private static func positiveMilliValue(_ raw: Any?) -> Double? {
        positiveNumber(raw).map { $0 / 1000 }
    }
}

/// 在后台直接读取 IOKit，不创建子进程，不记录序列号或其他原始设备信息。
enum SystemPowerReader {
    static func read() -> PowerSnapshot {
        var registry: [String: Any] = [:]
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS {
                registry = properties?.takeRetainedValue() as? [String: Any] ?? [:]
            }
        }
        var source: [String: Any] = [:]
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for entry in sources {
                guard let description = IOPSGetPowerSourceDescription(info, entry)?.takeUnretainedValue()
                    as? [String: Any], description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                source = description
                break
            }
        }
        return PowerSnapshot.decode(registry: registry, source: source)
    }
}

/// 显示层按格式化结果比较，传感器小幅变化不会让未变化的文字重复布局。
struct PowerPresentation: Equatable {
    let state: PowerState
    let percent: String
    let adapter: String
    let adapterRating: String
    let contract: String
    let inputVoltage: String
    let inputWatts: String
    let batteryVoltage: String
    let chargingWatts: String
    let menuValue: String
    let showAdapter: Bool
    let showBattery: Bool

    init(snapshot: PowerSnapshot, showPower: Bool) {
        state = snapshot.state
        percent = Self.format(snapshot.batteryPercent, decimals: 0, unit: "%")
        showAdapter = snapshot.externalConnected == true
        showBattery = snapshot.state == .battery
        adapter = showAdapter ? (snapshot.adapterName ?? "名称暂不可用") : (showBattery ? "未连接" : "暂不可用")
        adapterRating = "额定功率 " + Self.format(snapshot.adapterWatts, decimals: 0, unit: " W")
        contract = Self.format(snapshot.adapterVoltage, decimals: 0, unit: " V") + " · "
            + Self.format(snapshot.adapterCurrent, decimals: 2, unit: " A")
        inputVoltage = Self.format(snapshot.inputVoltage, decimals: 2, unit: " V")
        inputWatts = Self.format(snapshot.inputWatts, decimals: 1, unit: " W")
        batteryVoltage = Self.format(snapshot.batteryVoltage, decimals: 2, unit: " V")
        chargingWatts = Self.format(snapshot.estimatedChargingWatts, decimals: 1, unit: " W", estimated: true)
        // 仅从共享快照选择功率来源；使用电池时没有外部输入，不显示旧读数或放电功率。
        switch (showPower, snapshot.state) {
        case (true, .charging): menuValue = chargingWatts
        case (true, .externalPower): menuValue = inputWatts
        default: menuValue = ""
        }
    }

    /// 提示与无障碍文案跟随实际数值来源；关闭或使用电池时不宣读隐藏的功率。
    var menuPowerDescription: String? {
        guard !menuValue.isEmpty else { return nil }
        let label = state == .charging ? "电池充电功率" : "系统输入功率"
        return "\(label) \(menuValue)"
    }

    /// 固定小数位和单位；估算功率加约等号，缺失时显示破折号。
    private static func format(_ value: Double?, decimals: Int, unit: String, estimated: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        return (estimated ? "≈" : "") + String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), decimals, value) + unit
    }
}
