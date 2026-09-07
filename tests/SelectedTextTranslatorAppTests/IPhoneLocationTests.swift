import Foundation
import Testing
@testable import SelectedTextTranslatorApp

/// Locks the form and USB-device contracts without connecting to the user's iPhone during tests.
struct IPhoneLocationTests {
    @Test
    func coordinateParserAcceptsDecimalDegrees() throws {
        let coordinate = try IPhoneCoordinate.parse(latitude: " 31.2304 ", longitude: "121.4737")

        #expect(coordinate.latitude == 31.2304)
        #expect(coordinate.longitude == 121.4737)
    }

    @Test
    func coordinateParserRejectsOutOfRangeValues() {
        #expect(throws: IPhoneCoordinateError.self) {
            try IPhoneCoordinate.parse(latitude: "90.1", longitude: "0")
        }
    }

    @Test
    func deviceParserReadsBridgeJSON() throws {
        let data = Data(
            #"""
            {"event":"devices","devices":[{"udid":"test-udid","name":"Test iPhone","productType":"iPhone15,4","osVersion":"26.2","transport":"USB"}]}
            """#.utf8
        )

        let devices = try IPhoneDeviceListParser.parse(data)

        #expect(devices.count == 1)
        #expect(devices[0].id == "test-udid")
        #expect(devices[0].isReadyForDeveloperLocation)
    }

    @Test
    func savedLocationStoreRoundTripsPresets() throws {
        let suiteName = "IPhoneLocationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IPhoneLocationStore(defaults: defaults)
        let location = SavedIPhoneLocation(
            name: "公司",
            coordinate: try IPhoneCoordinate.parse(latitude: "31.2304", longitude: "121.4737")
        )

        store.save([location])

        #expect(store.load() == [location])
    }
}
