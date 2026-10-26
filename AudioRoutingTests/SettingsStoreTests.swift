import XCTest
@testable import AudioRouting

final class SettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AudioRoutingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testSaveAndReloadRoundTrips() {
        let settings = AppRoutingSettings(routes: ["com.spotify.client": "headphones", "us.zoom.xos": "speakers"])

        UserDefaultsSettingsStore(defaults: defaults).save(settings)
        let loaded = UserDefaultsSettingsStore(defaults: defaults).load()

        XCTAssertEqual(loaded, settings)
    }

    func testUsesAppRoutingSettingsKeyAsJSON() throws {
        UserDefaultsSettingsStore(defaults: defaults).save(AppRoutingSettings(routes: ["a": "b"]))

        let data = try XCTUnwrap(defaults.data(forKey: "AppRoutingSettings"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["routes"] as? [String: String], ["a": "b"])
    }

    func testMissingDataLoadsEmpty() {
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).load(), AppRoutingSettings())
    }

    func testCorruptJSONLoadsEmpty() {
        defaults.set(Data("{not json".utf8), forKey: "AppRoutingSettings")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).load(), AppRoutingSettings())
    }

    func testWrongTypeLoadsEmpty() {
        defaults.set("a string", forKey: "AppRoutingSettings")
        XCTAssertEqual(UserDefaultsSettingsStore(defaults: defaults).load(), AppRoutingSettings())
    }
}
