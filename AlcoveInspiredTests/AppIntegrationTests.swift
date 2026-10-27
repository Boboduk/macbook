import AppKit
import IslandCore
import SwiftUI
import XCTest
@testable import AlcoveInspired

/// Integration tests of the app layer. They run inside the real app process
/// (test host) on macOS, so they exercise AppKit, AppleScript and the system
/// services for real. Pure logic is tested in `Packages/IslandCore`.

@MainActor
final class AppleScriptRunnerTests: XCTestCase {
    func testListResultIsConvertedToSwiftValues() {
        let done = expectation(description: "script finished")
        AppleScriptRunner.shared.run(#"return {"playing", "Song", 215.5, 3, true}"#) { result in
            defer { done.fulfill() }
            guard case let .success(descriptor) = result else {
                return XCTFail("script failed: \(result)")
            }
            let values = descriptor.listValues
            XCTAssertEqual(values.count, 5)
            XCTAssertEqual(values[0] as? String, "playing")
            XCTAssertEqual(values[1] as? String, "Song")
            XCTAssertEqual(values[2] as? Double, 215.5)
            XCTAssertEqual(values[3] as? Double, 3)
            XCTAssertEqual(values[4] as? Bool, true)
        }
        wait(for: [done], timeout: 20)
    }

    func testStateScriptShapeParsesIntoSnapshot() {
        let done = expectation(description: "script finished")
        AppleScriptRunner.shared.run(#"return {"paused", "Name", "Artist", "Album", 200.0, 12.5, "00000000000000AB"}"#) { result in
            defer { done.fulfill() }
            guard case let .success(descriptor) = result else {
                return XCTFail("script failed: \(result)")
            }
            let snapshot = NowPlayingParser.parseScriptFields(descriptor.listValues, source: .appleMusic, at: Date())
            XCTAssertEqual(snapshot?.state, .paused)
            XCTAssertEqual(snapshot?.track?.title, "Name")
            XCTAssertEqual(snapshot?.track?.duration, 200)
            XCTAssertEqual(snapshot?.position?.elapsed, 12.5)
            XCTAssertEqual(snapshot?.position?.rate, 0)
            XCTAssertEqual(snapshot?.track?.id, "00000000000000AB")
        }
        wait(for: [done], timeout: 20)
    }

    func testCompileErrorsAreReported() {
        let done = expectation(description: "script finished")
        AppleScriptRunner.shared.run("this is (not valid", cacheable: false) { result in
            defer { done.fulfill() }
            guard case let .failure(failure) = result, case .compile = failure else {
                return XCTFail("expected a compile failure, got \(result)")
            }
        }
        wait(for: [done], timeout: 20)
    }

    func testFourCharacterCodes() {
        XCTAssertEqual(AEType.code("utxt"), 0x7574_7874)
        XCTAssertEqual(AEType.wildcard, 0x2A2A_2A2A)
    }
}

@MainActor
final class CoordinatorIntegrationTests: XCTestCase {
    private func makeCoordinator(_ change: (inout IslandSettings) -> Void = { _ in }) -> IslandCoordinator {
        var settings = IslandSettings.default
        change(&settings)
        return IslandCoordinator(settings: settings, log: DiagnosticsLog())
    }

    func testVolumeEventShowsWideCompactHUD() {
        let coordinator = makeCoordinator()
        coordinator.post(.volumeChanged(level: 0.5, muted: false, device: nil))
        guard case let .compact(activity, _) = coordinator.presentation else {
            return XCTFail("expected compact HUD, got \(coordinator.presentation)")
        }
        XCTAssertEqual(activity.id, .volumeHUD)
        let expected = IslandLayout.frame(for: .compact(.wide, hovered: false), metrics: coordinator.metrics, config: coordinator.layoutConfig)
        XCTAssertEqual(coordinator.islandFrame, expected)
    }

    func testBannerStyleSettingIsApplied() {
        let coordinator = makeCoordinator { $0.volume.hud.style = .banner }
        coordinator.post(.volumeChanged(level: 0.5, muted: true, device: "AirPods"))
        guard case .banner = coordinator.presentation else {
            return XCTFail("expected banner, got \(coordinator.presentation)")
        }
    }

    func testDisabledIslandIsHiddenAndComesBack() {
        let coordinator = makeCoordinator { $0.general.isEnabled = false }
        XCTAssertEqual(coordinator.presentation, .hidden)
        coordinator.apply(settings: .default)
        XCTAssertEqual(coordinator.presentation, .idle(hovered: false))
    }

    func testPinnedSettingKeepsIslandExpanded() {
        let coordinator = makeCoordinator { $0.general.isPinned = true }
        XCTAssertTrue(coordinator.presentation.isExpanded)
        coordinator.tapOutside()
        XCTAssertTrue(coordinator.presentation.isExpanded)
    }

    func testTapAndClickOutside() {
        let coordinator = makeCoordinator()
        coordinator.tap()
        XCTAssertTrue(coordinator.presentation.isExpanded)
        coordinator.tapOutside()
        XCTAssertFalse(coordinator.presentation.isExpanded)
    }

    func testLayoutSettingsChangePanelAndIsland() {
        let coordinator = makeCoordinator()
        let standard = coordinator.panelSize
        var large = IslandSettings.default
        large.appearance.size = .large
        coordinator.apply(settings: large)
        XCTAssertEqual(coordinator.layoutConfig.scale, IslandSizeOption.large.scale)
        XCTAssertGreaterThan(coordinator.panelSize.width, standard.width)
    }

    func testSwipeOutcomesReachTheApp() {
        let coordinator = makeCoordinator()
        var outcomes: [SwipeOutcome] = []
        coordinator.onSwipeOutcome = { outcomes.append($0) }
        coordinator.post(.nowPlaying(NowPlayingSnapshot(
            source: .spotify,
            track: TrackInfo(id: "x", title: "T", artist: "A", album: "B", duration: 100),
            state: .playing,
            position: nil
        )))
        coordinator.swipe(.left)
        coordinator.swipe(.down)
        XCTAssertEqual(outcomes, [.nextTrack, .expanded])
    }
}

@MainActor
final class ControllerIntegrationTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "AlcoveInspiredTests.\(UUID().uuidString)")!
    }

    func testTimerPublishesLiveActivityAndRestoresAfterRelaunch() {
        let defaults = makeDefaults()
        var events: [IslandEvent] = []
        let timer = TimerController(settings: IslandSettings.Timer(), defaults: defaults)
        timer.onEvent = { events.append($0) }

        timer.startCountdown(duration: 120)
        XCTAssertTrue(timer.countdown.isRunning)
        XCTAssertEqual(events.last, .timerActive(.countdown, isRunning: true))

        timer.pauseCountdown()
        XCTAssertEqual(events.last, .timerActive(.countdown, isRunning: false))

        // A new controller with the same storage simulates an app restart.
        let restored = TimerController(settings: IslandSettings.Timer(), defaults: defaults)
        restored.restore()
        XCTAssertTrue(restored.countdown.isPaused)
        XCTAssertEqual(restored.countdown.remaining(at: Date()), timer.countdown.remaining(at: Date()), accuracy: 0.5)

        timer.resetCountdown()
        XCTAssertEqual(events.last, .timerActive(nil, isRunning: false))
    }

    func testStopwatchLaps() {
        let timer = TimerController(settings: IslandSettings.Timer(), defaults: makeDefaults())
        timer.toggleStopwatch()
        XCTAssertTrue(timer.stopwatch.isRunning)
        XCTAssertEqual(timer.activeMode, .stopwatch)
        timer.lap()
        timer.lap()
        XCTAssertEqual(timer.stopwatch.laps.count, 2)
        timer.toggleStopwatch()
        XCTAssertFalse(timer.stopwatch.isRunning)
        timer.resetStopwatch()
        XCTAssertNil(timer.activeMode)
    }

    func testSettingsStoreSanitizesPersistsAndNotifies() {
        let defaults = makeDefaults()
        let store = SettingsStore(persistence: SettingsPersistence(defaults: defaults))
        var notifications = 0
        store.observe { _, _ in notifications += 1 }

        store.update { $0.appearance.cornerRadius = 99 }
        XCTAssertEqual(store.settings.appearance.cornerRadius, 36, "values are clamped")
        XCTAssertEqual(notifications, 1)

        store.update { $0.appearance.cornerRadius = 50 }
        XCTAssertEqual(notifications, 1, "no notification when the sanitized value is unchanged")

        let reloaded = SettingsStore(persistence: SettingsPersistence(defaults: defaults))
        XCTAssertEqual(reloaded.settings.appearance.cornerRadius, 36, "persisted across instances")

        reloaded.resetToDefaults()
        XCTAssertEqual(reloaded.settings, .default)
    }

    func testTrackIdentity() {
        let a = TrackInfo(id: "1", title: "Song", artist: "A", album: "B", duration: nil)
        let sameMetadata = TrackInfo(id: "2", title: "Song", artist: "A", album: "B", duration: nil)
        let other = TrackInfo(id: "3", title: "Other", artist: "A", album: "B", duration: nil)
        XCTAssertTrue(MusicController.isSameTrack(a, sameMetadata))
        XCTAssertFalse(MusicController.isSameTrack(a, other))
    }

    func testArtworkColorIsReadableOnBlack() {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(srgbRed: 0.3, green: 0.05, blue: 0.05, alpha: 1).setFill()
            rect.fill()
            return true
        }
        guard let color = MusicController.readableColor(from: image),
              let rgb = NSColor(color).usingColorSpace(.sRGB)
        else { return XCTFail("no color") }
        XCTAssertGreaterThanOrEqual(rgb.brightnessComponent, 0.79)
        XCTAssertGreaterThan(rgb.redComponent, rgb.blueComponent)
    }
}

@MainActor
final class WindowAndGeometryTests: XCTestCase {
    func testPanelConfiguration() {
        let panel = IslandPanel(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
        XCTAssertLessThan(panel.level.rawValue, NSWindow.Level.popUpMenu.rawValue)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        let requested = NSRect(x: 0, y: 10_000, width: 10, height: 10)
        XCTAssertEqual(panel.constrainFrameRect(requested, to: nil), requested, "the panel may sit over the menu bar")
    }

    func testPanelFrameIsFlushWithTheTopOfEveryScreen() {
        for screen in NSScreen.screens {
            let metrics = ScreenPositioning.metrics(for: screen)
            XCTAssertEqual(metrics.hasNotch, screen.notchRect != nil)
            XCTAssertGreaterThan(metrics.notchSize.width, 0)
            let size = IslandLayout.panelSize(metrics: metrics, config: IslandLayoutConfig())
            let frame = ScreenPositioning.panelFrame(for: screen, panelSize: size)
            XCTAssertEqual(frame.maxY, screen.frame.maxY, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(frame.minX, screen.frame.minX - 0.5)
            XCTAssertLessThanOrEqual(frame.maxX, screen.frame.maxX + 0.5)
        }
    }

    func testIslandShapeStaysInsideItsRect() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 40)
        let path = IslandShape(topRadius: 6, bottomRadius: 14).path(in: rect)
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.maxX, 200, accuracy: 0.01)
        XCTAssertEqual(path.boundingRect.maxY, 40, accuracy: 0.01)
        let extreme = IslandShape(topRadius: 500, bottomRadius: 500).path(in: rect)
        XCTAssertFalse(extreme.isEmpty)
        XCTAssertLessThanOrEqual(extreme.boundingRect.maxX, 200.01, "radii are clamped")
    }

    func testAlignedSecondsSchedule() {
        let anchor = Date(timeIntervalSinceReferenceDate: 100.25)
        let start = Date(timeIntervalSinceReferenceDate: 90)
        var iterator = AlignedSecondsSchedule(anchor: anchor).entries(from: start, mode: .normal).makeIterator()
        XCTAssertEqual(iterator.next(), start)
        XCTAssertEqual(iterator.next()?.timeIntervalSinceReferenceDate ?? 0, 90.27, accuracy: 0.0001)
        XCTAssertEqual(iterator.next()?.timeIntervalSinceReferenceDate ?? 0, 91.27, accuracy: 0.0001)
    }

    func testSystemServicesStartAndStopCleanly() {
        let audio = SystemAudioService()
        audio.start()
        if let volume = audio.volume {
            XCTAssertTrue((0...1).contains(volume))
        }
        audio.stop()

        let power = PowerSourceService.currentState()
        XCTAssertTrue((0...100).contains(power.percent))

        let brightness = BrightnessService()
        if let level = brightness.brightness() {
            XCTAssertTrue((0...1).contains(level))
        }
    }
}
