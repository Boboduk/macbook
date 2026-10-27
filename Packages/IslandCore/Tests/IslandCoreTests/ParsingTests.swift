import XCTest
@testable import IslandCore

final class ParsingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 5_000)

    func testAppleMusicNotification() {
        let info: [AnyHashable: Any] = [
            "Name": "Song", "Artist": "Artist", "Album": "Album",
            "Total Time": 215_000, "Player State": "Playing", "PersistentID": 1234567890123,
        ]
        let snapshot = NowPlayingParser.parseNotification(info, source: .appleMusic, at: now)
        XCTAssertEqual(snapshot.state, .playing)
        XCTAssertEqual(snapshot.track?.title, "Song")
        XCTAssertEqual(snapshot.track?.duration, 215)
        XCTAssertEqual(snapshot.track?.id, "1234567890123")
        XCTAssertNil(snapshot.position, "Music does not send a position; it is fetched separately")
    }

    func testSpotifyNotification() {
        let info: [AnyHashable: Any] = [
            "Name": "Track", "Artist": "Band", "Album": "LP",
            "Duration": 180_500, "Playback Position": 42.5,
            "Player State": "Paused", "Track ID": "spotify:track:abc",
        ]
        let snapshot = NowPlayingParser.parseNotification(info, source: .spotify, at: now)
        XCTAssertEqual(snapshot.state, .paused)
        XCTAssertEqual(snapshot.track?.id, "spotify:track:abc")
        XCTAssertEqual(snapshot.track?.duration ?? 0, 180.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.position, PlaybackPosition(elapsed: 42.5, timestamp: now, rate: 0))
    }

    func testStoppedNotificationHasNoTrack() {
        let snapshot = NowPlayingParser.parseNotification(["Player State": "Stopped"], source: .appleMusic, at: now)
        XCTAssertEqual(snapshot.state, .stopped)
        XCTAssertNil(snapshot.track)
    }

    func testStreamWithoutDurationOrIdentifier() {
        let info: [AnyHashable: Any] = ["Name": "Radio", "Player State": "Playing", "Total Time": 0]
        let snapshot = NowPlayingParser.parseNotification(info, source: .appleMusic, at: now)
        XCTAssertNil(snapshot.track?.duration)
        XCTAssertEqual(snapshot.track?.id, NowPlayingParser.syntheticID(title: "Radio", artist: "", album: ""))
    }

    func testScriptFieldsMusic() {
        let fields: [Any?] = ["playing", "Song", "Artist", "Album", 215.5, 12.25, "ABCDEF"]
        let snapshot = NowPlayingParser.parseScriptFields(fields, source: .appleMusic, at: now)
        XCTAssertEqual(snapshot?.track?.duration, 215.5)
        XCTAssertEqual(snapshot?.position?.elapsed, 12.25)
        XCTAssertEqual(snapshot?.position?.rate, 1)
        XCTAssertEqual(snapshot?.track?.id, "ABCDEF")
    }

    func testScriptFieldsSpotifyDurationInMilliseconds() {
        let fields: [Any?] = ["paused", "Song", "Artist", "Album", 200_000, 3, "spotify:track:x"]
        let snapshot = NowPlayingParser.parseScriptFields(fields, source: .spotify, at: now)
        XCTAssertEqual(snapshot?.track?.duration, 200)
        XCTAssertEqual(snapshot?.position?.rate, 0)
    }

    func testScriptFieldsInvalid() {
        XCTAssertNil(NowPlayingParser.parseScriptFields(["playing"], source: .appleMusic, at: now))
        let stopped = NowPlayingParser.parseScriptFields(["stopped", "", "", "", 0, 0, ""], source: .appleMusic, at: now)
        XCTAssertEqual(stopped?.state, .stopped)
        XCTAssertNil(stopped?.track)
    }

    func testValueCoercion() {
        XCTAssertEqual(NowPlayingParser.number("12.5"), 12.5)
        XCTAssertEqual(NowPlayingParser.number(NSNumber(value: 7)), 7)
        XCTAssertNil(NowPlayingParser.number(nil))
        XCTAssertEqual(NowPlayingParser.string(NSNumber(value: 3)), "3")
    }

    func testMediaKeyDecoding() {
        // Volume up, key down: code 0 << 16 | 0x0A << 8
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: 0x0A00), MediaKeyEvent(key: .soundUp, isKeyDown: true, isRepeat: false))
        // Brightness down (3), key up
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: (3 << 16) | 0x0B00), MediaKeyEvent(key: .brightnessDown, isKeyDown: false, isRepeat: false))
        // Mute (7), key down, repeat
        XCTAssertEqual(MediaKeyEvent(subtype: 8, data1: (7 << 16) | 0x0A01), MediaKeyEvent(key: .mute, isKeyDown: true, isRepeat: true))
        XCTAssertNil(MediaKeyEvent(subtype: 7, data1: 0x0A00), "other subtypes are not media keys")
        XCTAssertNil(MediaKeyEvent(subtype: 8, data1: (99 << 16) | 0x0A00), "unknown key code")
        XCTAssertTrue(MediaKey.mute.isVolumeKey)
        XCTAssertTrue(MediaKey.brightnessUp.isBrightnessKey)
        XCTAssertFalse(MediaKey.play.isVolumeKey)
    }

    func testLevelStepper() {
        XCTAssertEqual(LevelStepper.step(0.5, up: true, fine: false), 0.5625)
        XCTAssertEqual(LevelStepper.step(0.5, up: false, fine: false), 0.4375)
        XCTAssertEqual(LevelStepper.step(0.52, up: false, fine: false), 0.5, "snaps to the grid")
        XCTAssertEqual(LevelStepper.step(1, up: true, fine: false), 1)
        XCTAssertEqual(LevelStepper.step(0, up: false, fine: false), 0)
        XCTAssertEqual(LevelStepper.step(0.5, up: true, fine: true), 0.5 + 1.0 / 64)
    }

    func testTrackpadSwipeFiresOncePerGesture() {
        var recognizer = ScrollGestureRecognizer(threshold: 30)
        // Natural scrolling: fingers moving down produce positive deltaY.
        XCTAssertNil(recognizer.handle(phase: .began, deltaX: 0, deltaY: 10, isInverted: true, timestamp: 0))
        XCTAssertNil(recognizer.handle(phase: .changed, deltaX: 1, deltaY: 10, isInverted: true, timestamp: 0))
        XCTAssertEqual(recognizer.handle(phase: .changed, deltaX: 0, deltaY: 15, isInverted: true, timestamp: 0), .down)
        XCTAssertNil(recognizer.handle(phase: .changed, deltaX: 0, deltaY: 50, isInverted: true, timestamp: 0))
        XCTAssertNil(recognizer.handle(phase: .ended, deltaX: 0, deltaY: 0, isInverted: true, timestamp: 0))
        XCTAssertNil(recognizer.handle(phase: .momentum, deltaX: 0, deltaY: 80, isInverted: true, timestamp: 0))

        // Classic scrolling: fingers moving left produce positive deltaX.
        XCTAssertNil(recognizer.handle(phase: .began, deltaX: 20, deltaY: 0, isInverted: false, timestamp: 0))
        XCTAssertEqual(recognizer.handle(phase: .changed, deltaX: 20, deltaY: 2, isInverted: false, timestamp: 0), .left)
    }

    func testDiagonalSwipeIsIgnored() {
        var recognizer = ScrollGestureRecognizer(threshold: 30)
        _ = recognizer.handle(phase: .began, deltaX: 0, deltaY: 0, isInverted: true, timestamp: 0)
        XCTAssertNil(recognizer.handle(phase: .changed, deltaX: 40, deltaY: 40, isInverted: true, timestamp: 0))
    }

    func testMouseWheelIsRateLimited() {
        var recognizer = ScrollGestureRecognizer(wheelInterval: 0.4)
        XCTAssertEqual(recognizer.handle(phase: .none, deltaX: 0, deltaY: -1, isInverted: false, timestamp: 10), .down)
        XCTAssertNil(recognizer.handle(phase: .none, deltaX: 0, deltaY: -1, isInverted: false, timestamp: 10.1))
        XCTAssertEqual(recognizer.handle(phase: .none, deltaX: 0, deltaY: 1, isInverted: false, timestamp: 10.5), .up)
    }

    func testPowerTransitions() {
        let base = PowerState(hasBattery: true, percent: 50, isCharging: false, isPluggedIn: false)
        var plugged = base
        plugged.isPluggedIn = true
        plugged.isCharging = true

        XCTAssertNil(PowerTransition.change(from: nil, to: base, lowThreshold: 20), "no event at launch")
        XCTAssertEqual(PowerTransition.change(from: base, to: plugged, lowThreshold: 20), .pluggedIn)
        XCTAssertEqual(PowerTransition.change(from: plugged, to: base, lowThreshold: 20), .unplugged)

        let at21 = PowerState(hasBattery: true, percent: 21, isCharging: false, isPluggedIn: false)
        let at20 = PowerState(hasBattery: true, percent: 20, isCharging: false, isPluggedIn: false)
        XCTAssertEqual(PowerTransition.change(from: at21, to: at20, lowThreshold: 20), .lowBattery)
        XCTAssertNil(PowerTransition.change(from: at20, to: at20, lowThreshold: 20))

        let at99 = PowerState(hasBattery: true, percent: 99, isCharging: true, isPluggedIn: true)
        let at100 = PowerState(hasBattery: true, percent: 100, isCharging: false, isPluggedIn: true)
        XCTAssertEqual(PowerTransition.change(from: at99, to: at100, lowThreshold: 20), .fullyCharged)
        XCTAssertNil(PowerTransition.change(from: .noBattery, to: .noBattery, lowThreshold: 20))
    }

    func testManualSchedulerOrderAndCancellation() {
        let scheduler = ManualScheduler()
        var fired: [String] = []
        scheduler.schedule(after: 2) { fired.append("b") }
        let token = scheduler.schedule(after: 1) { fired.append("cancelled") }
        scheduler.schedule(after: 1) {
            fired.append("a")
            scheduler.schedule(after: 0.5) { fired.append("nested") }
        }
        token.cancel()
        scheduler.advance(by: 3)
        XCTAssertEqual(fired, ["a", "nested", "b"])
        XCTAssertEqual(scheduler.pendingCount, 0)
    }
}
