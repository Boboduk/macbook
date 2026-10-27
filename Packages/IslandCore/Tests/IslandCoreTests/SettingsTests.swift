import XCTest
@testable import IslandCore

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "IslandCoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testMissingDocumentGivesDefaults() {
        XCTAssertEqual(SettingsPersistence(defaults: defaults).load(), .default)
    }

    func testRoundTripSurvivesNewInstance() {
        var settings = IslandSettings.default
        settings.general.hoverBehavior = .highlight
        settings.general.isPinned = true
        settings.appearance.accent = .pink
        settings.appearance.cornerRadius = 30
        settings.music.preferredSource = .spotify
        settings.timer.defaultDuration = 1_500
        settings.power.lowBatteryThreshold = 15
        SettingsPersistence(defaults: defaults).save(settings)

        // A new persistence object simulates an app restart.
        XCTAssertEqual(SettingsPersistence(defaults: defaults).load(), settings)
    }

    func testPartialDocumentFillsDefaults() {
        let json = #"{"general":{"hoverBehavior":"none"},"music":{"pausedTimeout":5}}"#
        let settings = SettingsPersistence.decode(Data(json.utf8))
        XCTAssertEqual(settings.general.hoverBehavior, HoverBehavior.none)
        XCTAssertEqual(settings.music.pausedTimeout, 5)
        XCTAssertTrue(settings.music.isEnabled)
        XCTAssertEqual(settings.appearance, IslandSettings.Appearance())
    }

    func testInvalidSectionFallsBackWithoutLosingOthers() {
        let json = #"{"appearance":{"accent":"rainbow"},"timer":{"defaultDuration":600},"unknown":{"x":1}}"#
        let settings = SettingsPersistence.decode(Data(json.utf8))
        XCTAssertEqual(settings.appearance.accent, .system, "unknown enum value → section defaults")
        XCTAssertEqual(settings.timer.defaultDuration, 600, "valid sections are kept")
    }

    func testCorruptDataGivesDefaults() {
        XCTAssertEqual(SettingsPersistence.decode(Data("not json".utf8)), .default)
        XCTAssertEqual(SettingsPersistence.decode(Data("[1,2]".utf8)), .default)
    }

    func testValuesAreClamped() {
        let json = #"{"general":{"hoverDelay":99},"appearance":{"cornerRadius":-4,"animationSpeed":10},"power":{"lowBatteryThreshold":1}}"#
        let settings = SettingsPersistence.decode(Data(json.utf8))
        XCTAssertEqual(settings.general.hoverDelay, 2)
        XCTAssertEqual(settings.appearance.cornerRadius, 12)
        XCTAssertEqual(settings.appearance.animationSpeed, 1.6)
        XCTAssertEqual(settings.power.lowBatteryThreshold, 5)
    }

    func testResetRemovesDocument() {
        let persistence = SettingsPersistence(defaults: defaults)
        var settings = IslandSettings.default
        settings.general.isEnabled = false
        persistence.save(settings)
        persistence.reset()
        XCTAssertEqual(persistence.load(), .default)
    }

    func testDerivedValues() {
        var settings = IslandSettings.default
        XCTAssertEqual(settings.availableTabs, [.music, .timer])
        settings.music.isEnabled = false
        XCTAssertEqual(settings.availableTabs, [.timer])
        XCTAssertFalse(settings.isModuleEnabled(.music))

        settings.appearance.size = .large
        settings.appearance.cornerRadius = 28
        XCTAssertEqual(settings.layoutConfig.scale, 1.12)
        XCTAssertEqual(settings.layoutConfig.expandedCornerRadius, 28)

        settings.general.hoverBehavior = .highlight
        settings.general.hoverDelay = 0.8
        XCTAssertEqual(settings.controllerBehavior.hover, .highlight)
        XCTAssertEqual(settings.controllerBehavior.hoverExpandDelay, 0.8)
        XCTAssertEqual(settings.controllerBehavior.availableTabs, [.timer])
    }
}
