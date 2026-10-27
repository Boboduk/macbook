import Foundation
import XCTest
@testable import IslandCore

final class SystemNotificationTests: XCTestCase {
    private func record(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    func testParsesUsernotedRecord() throws {
        let data = try record([
            "app": "com.apple.MobileSMS",
            "date": 752_000_000.0,
            "req": ["titl": "Anna", "subt": "Family", "body": "Dinner at 7?", "iden": "x"],
        ])
        let notification = NotificationRecordParser.parse(recordID: 42, data: data)
        XCTAssertEqual(notification?.bundleIdentifier, "com.apple.MobileSMS")
        XCTAssertEqual(notification?.title, "Anna")
        XCTAssertEqual(notification?.subtitle, "Family")
        XCTAssertEqual(notification?.body, "Dinner at 7?")
        XCTAssertEqual(notification?.date, Date(timeIntervalSinceReferenceDate: 752_000_000))
        XCTAssertEqual(notification?.recordID, 42)
    }

    func testDeliveredDateColumnWinsAndAppFallsBackToJoin() throws {
        let data = try record(["req": ["titl": "Build finished"]])
        let notification = NotificationRecordParser.parse(recordID: 1, data: data, fallbackBundleIdentifier: "com.apple.dt.Xcode", deliveredDate: 10)
        XCTAssertEqual(notification?.bundleIdentifier, "com.apple.dt.Xcode")
        XCTAssertEqual(notification?.date, Date(timeIntervalSinceReferenceDate: 10))
    }

    func testRejectsGarbageAndEmptyRecords() throws {
        XCTAssertNil(NotificationRecordParser.parse(recordID: 1, data: Data("nope".utf8)))
        XCTAssertNil(NotificationRecordParser.parse(recordID: 1, data: try record(["app": "a.b", "req": ["titl": "  "]])), "whitespace only")
        XCTAssertNil(NotificationRecordParser.parse(recordID: 1, data: try record(["req": ["titl": "No app"]])), "no bundle id")
    }

    func testFilter() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let fresh = SystemNotification(recordID: 1, bundleIdentifier: "com.tinyspeck.slackmacgap", title: "Hi", subtitle: "", body: "", date: now)
        XCTAssertTrue(SystemNotificationFilter.shouldShow(fresh, ownBundleIdentifier: "me.app", mutedApps: [], now: now))
        XCTAssertFalse(SystemNotificationFilter.shouldShow(fresh, ownBundleIdentifier: "com.tinyspeck.slackmacgap", mutedApps: [], now: now), "own notifications")
        XCTAssertFalse(SystemNotificationFilter.shouldShow(fresh, ownBundleIdentifier: nil, mutedApps: ["com.tinyspeck.slackmacgap"], now: now), "muted")
        XCTAssertFalse(SystemNotificationFilter.shouldShow(fresh, ownBundleIdentifier: nil, mutedApps: [], now: now + 600), "stale")
    }

    func testBannerCloseActionMatching() {
        XCTAssertTrue(BannerCloseAction.isClose("Name:Close\nTarget:0x0\nSelector:(null)"))
        XCTAssertTrue(BannerCloseAction.isClose("Name:Закрыть\nTarget:0x0\nSelector:(null)"))
        XCTAssertTrue(BannerCloseAction.isClose("Close"))
        XCTAssertFalse(BannerCloseAction.isClose("Name:Show Details\nTarget:0x0\nSelector:(null)"))
        XCTAssertFalse(BannerCloseAction.isClose("AXPress"))
        XCTAssertEqual(BannerCloseAction.displayLabel(of: "Name:Options\nTarget:0x0"), "Options")
    }

    func testRouterMirrorsSystemNotifications() {
        let scheduler = ManualScheduler()
        let activities = ActivityManager(scheduler: scheduler)
        var settings = IslandSettings.default
        let router = EventRouter(activities: activities, settings: settings)
        let notification = SystemNotification(recordID: 7, bundleIdentifier: "com.apple.mail", title: "", subtitle: "Re: plan", body: "Looks good", date: nil)

        router.handle(.systemNotification(notification, appName: "Mail"))
        XCTAssertNil(activities.currentTransient, "mirroring is opt-in")

        settings.notifications.mirrorSystemNotifications = true
        router.update(settings: settings)
        router.handle(.systemNotification(notification, appName: "Mail"))
        guard case let .message(message)? = activities.currentTransient?.payload else { return XCTFail("expected a banner") }
        XCTAssertEqual(message.title, "Mail", "empty title falls back to the app name")
        XCTAssertEqual(message.body, "Re: plan — Looks good")
        XCTAssertEqual(message.appBundleIdentifier, "com.apple.mail")
        XCTAssertEqual(activities.currentTransient?.style, .banner)

        settings.notifications.showSystemNotificationText = false
        router.update(settings: settings)
        activities.removeAll()
        router.handle(.systemNotification(notification, appName: "Mail"))
        guard case let .message(hidden)? = activities.currentTransient?.payload else { return XCTFail() }
        XCTAssertEqual(hidden.body, "", "message text hidden for privacy")

        settings.notifications.mutedApps = ["com.apple.mail"]
        router.update(settings: settings)
        activities.removeAll()
        router.handle(.systemNotification(notification, appName: "Mail"))
        XCTAssertNil(activities.currentTransient)
    }

    func testOldSettingsDocumentGetsNewDefaults() {
        let json = #"{"notifications":{"duration":6},"music":{"pausedTimeout":10}}"#
        let settings = SettingsPersistence.decode(Data(json.utf8))
        XCTAssertEqual(settings.notifications.duration, 6)
        XCTAssertFalse(settings.notifications.mirrorSystemNotifications)
        XCTAssertTrue(settings.music.useSystemNowPlaying)
        XCTAssertEqual(settings.notifications.mutedApps, [])
    }
}

final class MediaRemoteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func line(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    func testReadyAndError() {
        XCTAssertEqual(MediaRemoteParser.parse(line: line(["type": "ready"])), .ready)
        XCTAssertEqual(MediaRemoteParser.parse(line: line(["type": "error", "message": "MediaRemote not found"])), .error("MediaRemote not found"))
        XCTAssertNil(MediaRemoteParser.parse(line: Data("{broken".utf8)))
        XCTAssertNil(MediaRemoteParser.parse(line: line(["type": "unknown"])))
    }

    func testNowPlayingFromBrowser() {
        let artwork = Data([0x89, 0x50, 0x4E, 0x47])
        let message = MediaRemoteParser.parse(line: line([
            "type": "nowPlaying", "playing": true,
            "bundleIdentifier": "com.google.Chrome", "appName": "Google Chrome",
            "title": "Lo-fi beats", "artist": "Channel", "album": "",
            "duration": 3600.5, "elapsed": 120.25, "timestamp": now.timeIntervalSince1970 - 2, "rate": 1,
            "id": "abc", "hasArtwork": true, "artwork": artwork.base64EncodedString(),
        ]), now: now)
        guard case let .nowPlaying(update)? = message, let snapshot = update.snapshot else { return XCTFail() }
        XCTAssertEqual(snapshot.source, .system)
        XCTAssertEqual(snapshot.playerBundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(snapshot.displayName, "Google Chrome")
        XCTAssertEqual(snapshot.track?.title, "Lo-fi beats")
        XCTAssertEqual(snapshot.track?.id, "abc")
        XCTAssertEqual(snapshot.track?.duration, 3600.5)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.position?.elapsed(at: now, duration: snapshot.track?.duration) ?? 0, 122.25, accuracy: 0.001)
        XCTAssertEqual(update.artwork, artwork)
        XCTAssertTrue(update.hasArtwork)
    }

    func testPausedWithoutTimestampOrArtwork() {
        let message = MediaRemoteParser.parse(line: line([
            "type": "nowPlaying", "playing": false, "title": "Episode 12", "artist": "Podcast",
            "elapsed": 30, "hasArtwork": true,
        ]), now: now)
        guard case let .nowPlaying(update)? = message, let snapshot = update.snapshot else { return XCTFail() }
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.position?.elapsed(at: now + 100, duration: nil), 30, "paused position does not advance")
        XCTAssertNil(update.artwork, "artwork unchanged")
        XCTAssertTrue(update.hasArtwork)
        XCTAssertNil(snapshot.track?.duration)
        XCTAssertEqual(snapshot.track?.id, NowPlayingParser.syntheticID(title: "Episode 12", artist: "Podcast", album: ""))
    }

    func testNothingPlaying() {
        let message = MediaRemoteParser.parse(line: line(["type": "nowPlaying", "empty": true, "playing": false]))
        XCTAssertEqual(message, .nowPlaying(MediaRemoteUpdate(snapshot: nil, artwork: nil, hasArtwork: false)))
    }

    func testCommandLines() {
        XCTAssertEqual(MediaRemoteCommand.togglePlayPause.line, "toggle")
        XCTAssertEqual(MediaRemoteCommand.nextTrack.line, "next")
        XCTAssertEqual(MediaRemoteCommand.previousTrack.line, "previous")
        XCTAssertEqual(MediaRemoteCommand.seek(12.5).line, "seek 12.500")
        XCTAssertEqual(MediaRemoteCommand.seek(-3).line, "seek 0.000")
    }

    func testScriptableSourcesExcludeSystem() {
        XCTAssertEqual(MusicSourceKind.scriptable, [.appleMusic, .spotify])
        let scripted = NowPlayingSnapshot(source: .spotify, track: nil, state: .stopped, position: nil)
        XCTAssertEqual(scripted.playerBundleIdentifier, "com.spotify.client")
        XCTAssertEqual(scripted.displayName, "Spotify")
    }

    func testTrackChangePeekCarriesPlayerName() {
        let activities = ActivityManager(scheduler: ManualScheduler())
        let router = EventRouter(activities: activities, settings: .default)
        router.handle(.trackChanged(TrackInfo(id: "1", title: "T", artist: "A", album: "B", duration: nil), source: .system, playerName: "VLC"))
        guard case let .track(track)? = activities.currentTransient?.payload else { return XCTFail() }
        XCTAssertEqual(track.playerName, "VLC")
    }
}
