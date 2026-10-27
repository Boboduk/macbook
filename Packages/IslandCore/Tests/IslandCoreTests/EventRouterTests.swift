import XCTest
@testable import IslandCore

final class EventRouterTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var activities: ActivityManager!
    private var router: EventRouter!
    private var log: DiagnosticsLog!

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        activities = ActivityManager(scheduler: scheduler)
        log = DiagnosticsLog(capacity: 50)
        router = EventRouter(activities: activities, settings: .default, log: log)
    }

    private func snapshot(_ state: PlaybackState, title: String = "Song") -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            source: .appleMusic,
            track: TrackInfo(id: "1", title: title, artist: "Artist", album: "Album", duration: 200),
            state: state,
            position: nil
        )
    }

    func testVolumeUsesSettingsDurationAndStyle() {
        var settings = IslandSettings.default
        settings.volume.hud.duration = 3
        settings.volume.hud.style = .banner
        router.update(settings: settings)

        router.handle(.volumeChanged(level: 0.4, muted: false, device: "Speakers"))
        let hud = activities.currentTransient
        XCTAssertEqual(hud?.id, .volumeHUD)
        XCTAssertEqual(hud?.style, .banner)
        XCTAssertEqual(hud?.payload, .level(LevelPayload(value: 0.4, isMuted: false, detail: "Speakers")))
        scheduler.advance(by: 2.9)
        XCTAssertNotNil(activities.currentTransient)
        scheduler.advance(by: 0.2)
        XCTAssertNil(activities.currentTransient)
    }

    func testDisabledModulesAreDropped() {
        var settings = IslandSettings.default
        settings.volume.hud.isEnabled = false
        settings.brightness.isEnabled = false
        settings.notifications.isEnabled = false
        settings.power.isEnabled = false
        router.update(settings: settings)

        router.handle(.volumeChanged(level: 0.4, muted: false, device: nil))
        router.handle(.brightnessChanged(level: 0.4))
        router.handle(.notice(Notice(id: "x", symbol: "bell", title: "t", body: "b")))
        router.handle(.power(PowerState(hasBattery: true, percent: 50, isCharging: true, isPluggedIn: true), .pluggedIn))
        XCTAssertNil(activities.currentTransient)
        XCTAssertTrue(activities.queuedActivities.isEmpty)
        XCTAssertFalse(log.entries.isEmpty, "drops are visible in diagnostics")
    }

    func testDisablingModuleEndsItsActivities() {
        router.handle(.nowPlaying(snapshot(.playing)))
        XCTAssertNotNil(activities.liveActivities[.music])

        var settings = IslandSettings.default
        settings.music.isEnabled = false
        router.update(settings: settings)
        XCTAssertNil(activities.liveActivities[.music])
    }

    func testPausedMusicExpiresAfterTimeout() {
        var settings = IslandSettings.default
        settings.music.pausedTimeout = 10
        router.update(settings: settings)

        router.handle(.nowPlaying(snapshot(.playing)))
        router.handle(.nowPlaying(snapshot(.paused)))
        scheduler.advance(by: 9)
        XCTAssertNotNil(activities.liveActivities[.music])
        router.handle(.nowPlaying(snapshot(.playing)))
        scheduler.advance(by: 100)
        XCTAssertNotNil(activities.liveActivities[.music], "resuming playback cancels the expiry")
        router.handle(.nowPlaying(snapshot(.paused)))
        scheduler.advance(by: 10)
        XCTAssertNil(activities.liveActivities[.music])
    }

    func testPausedMusicHiddenImmediatelyWithZeroTimeout() {
        var settings = IslandSettings.default
        settings.music.pausedTimeout = 0
        router.update(settings: settings)
        router.handle(.nowPlaying(snapshot(.playing)))
        router.handle(.nowPlaying(snapshot(.paused)))
        XCTAssertNil(activities.liveActivities[.music])
    }

    func testStoppedOrMissingPlayerEndsMusic() {
        router.handle(.nowPlaying(snapshot(.playing)))
        router.handle(.nowPlaying(nil))
        XCTAssertNil(activities.liveActivities[.music])
    }

    func testTrackChangePeek() {
        router.handle(.trackChanged(TrackInfo(id: "2", title: "New", artist: "A", album: "B", duration: nil), source: .spotify))
        XCTAssertEqual(activities.currentTransient?.id, .musicPeek)
        XCTAssertEqual(activities.currentTransient?.style, .banner)

        var settings = IslandSettings.default
        settings.music.peekOnTrackChange = false
        router.update(settings: settings)
        activities.removeAll()
        router.handle(.trackChanged(TrackInfo(id: "3", title: "Next", artist: "A", album: "B", duration: nil), source: .spotify))
        XCTAssertNil(activities.currentTransient)
    }

    func testTimerLiveActivityAndFinish() {
        router.handle(.timerActive(.countdown, isRunning: true))
        XCTAssertEqual(activities.liveActivities[.timer]?.priority, .high)
        router.handle(.timerActive(.countdown, isRunning: false))
        XCTAssertEqual(activities.liveActivities[.timer]?.priority, .normal)
        router.handle(.timerActive(nil, isRunning: false))
        XCTAssertNil(activities.liveActivities[.timer])

        router.handle(.timerFinished(title: "Timer", body: "Done"))
        XCTAssertEqual(activities.currentTransient?.priority, .critical)
    }

    func testCompactToggleRemovesLiveActivity() {
        router.handle(.timerActive(.stopwatch, isRunning: true))
        var settings = IslandSettings.default
        settings.timer.showCompact = false
        router.update(settings: settings)
        XCTAssertNil(activities.liveActivities[.timer])
        router.handle(.timerActive(.stopwatch, isRunning: true))
        XCTAssertNil(activities.liveActivities[.timer])
    }

    func testPowerEvents() {
        let charging = PowerState(hasBattery: true, percent: 55, isCharging: true, isPluggedIn: true)
        router.handle(.power(charging, .pluggedIn))
        XCTAssertEqual(activities.currentTransient?.id, .power)

        let low = PowerState(hasBattery: true, percent: 19, isCharging: false, isPluggedIn: false)
        router.handle(.power(low, .lowBattery))
        XCTAssertEqual(activities.currentTransient?.id, .powerLow, "low battery is more important")

        var settings = IslandSettings.default
        settings.power.showChargingChanges = false
        router.update(settings: settings)
        activities.removeAll()
        router.handle(.power(charging, .pluggedIn))
        XCTAssertNil(activities.currentTransient)
    }

    func testNoticeUsesSettingsDurationUnlessOverridden() {
        var settings = IslandSettings.default
        settings.notifications.duration = 5
        router.update(settings: settings)
        router.handle(.notice(Notice(id: "a", symbol: "bell", title: "A", body: "")))
        router.handle(.notice(Notice(id: "b", symbol: "bell", title: "B", body: "", duration: 2)))
        XCTAssertEqual(activities.currentTransient?.transientDuration, 5)
        XCTAssertEqual(activities.queuedActivities.first?.transientDuration, 2)
    }

    func testDiagnosticsLogIsBounded() {
        let log = DiagnosticsLog(capacity: 3)
        for index in 0..<10 { log.append("test", "\(index)") }
        XCTAssertEqual(log.entries.map(\.message), ["7", "8", "9"])
    }
}
