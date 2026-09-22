import Foundation

struct IPhoneCoordinate: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    /// Converts decimal-degree form fields into the bounded coordinate accepted by Core Location.
    static func parse(latitude rawLatitude: String, longitude rawLongitude: String) throws -> IPhoneCoordinate {
        let latitudeText = rawLatitude.trimmingCharacters(in: .whitespacesAndNewlines)
        let longitudeText = rawLongitude.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let latitude = Double(latitudeText), latitude.isFinite else {
            throw IPhoneCoordinateError.invalidLatitude
        }
        guard let longitude = Double(longitudeText), longitude.isFinite else {
            throw IPhoneCoordinateError.invalidLongitude
        }
        guard (-90 ... 90).contains(latitude) else {
            throw IPhoneCoordinateError.latitudeOutOfRange
        }
        guard (-180 ... 180).contains(longitude) else {
            throw IPhoneCoordinateError.longitudeOutOfRange
        }
        return IPhoneCoordinate(latitude: latitude, longitude: longitude)
    }

    var displayText: String {
        String(
            format: "%.6f, %.6f",
            locale: Locale(identifier: "en_US_POSIX"),
            latitude,
            longitude
        )
    }

    var latitudeInputText: String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), latitude)
    }

    var longitudeInputText: String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), longitude)
    }
}

struct SavedIPhoneLocation: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let coordinate: IPhoneCoordinate

    init(id: UUID = UUID(), name: String, coordinate: IPhoneCoordinate) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
}

/// Stores user-created location presets independently from the active device session.
final class IPhoneLocationStore {
    private static let userDefaultsKey = "iphone.savedLocations"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [SavedIPhoneLocation] {
        guard
            let data = defaults.data(forKey: Self.userDefaultsKey),
            let locations = try? JSONDecoder().decode([SavedIPhoneLocation].self, from: data)
        else {
            return []
        }
        return locations
    }

    func save(_ locations: [SavedIPhoneLocation]) {
        guard let data = try? JSONEncoder().encode(locations) else {
            return
        }
        defaults.set(data, forKey: Self.userDefaultsKey)
    }
}

enum IPhoneCoordinateError: LocalizedError {
    case invalidLatitude
    case invalidLongitude
    case latitudeOutOfRange
    case longitudeOutOfRange

    var errorDescription: String? {
        switch self {
        case .invalidLatitude:
            return "请输入有效的纬度，例如 31.2304。"
        case .invalidLongitude:
            return "请输入有效的经度，例如 121.4737。"
        case .latitudeOutOfRange:
            return "纬度必须在 -90 到 90 之间。"
        case .longitudeOutOfRange:
            return "经度必须在 -180 到 180 之间。"
        }
    }
}

struct ConnectedIPhone: Identifiable, Hashable {
    let id: String
    let name: String
    let productType: String
    let osVersion: String
    let transport: String

    var displayName: String {
        "\(name) · \(productType) · iOS \(osVersion)"
    }

    var isReadyForDeveloperLocation: Bool {
        transport == "USB" && majorOSVersion >= 17
    }

    /// DVT location simulation and app launch use the iOS 17+ native device tunnel.
    private var majorOSVersion: Int {
        Int(osVersion.split(separator: ".").first ?? "0") ?? 0
    }

    var readinessMessage: String {
        if transport != "USB" {
            return "请通过 USB 连接并解锁 iPhone。"
        }
        if majorOSVersion < 17 {
            return "当前定位服务仅支持 iOS 17 及以上真机。"
        }
        return "设备已连接；定位操作需要 iPhone 已开启开发者模式。"
    }
}

struct CurrentIPhoneLocation: Equatable {
    let coordinate: IPhoneCoordinate
    /// Horizontal accuracy reported by Core Location, in meters.
    let horizontalAccuracy: Double
}
