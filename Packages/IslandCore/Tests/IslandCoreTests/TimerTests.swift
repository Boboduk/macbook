import XCTest
@testable import IslandCore

final class TimerTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testCountdownLifecycle() {
        var timer = CountdownTimer(duration: 60)
        XCTAssertEqual(timer.state, .idle)
        XCTAssertEqual(timer.remaining(at: t0), 60)

        timer.start(at: t0)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.remaining(at: t0 + 15), 45)
        XCTAssertEqual(timer.progress(at: t0 + 15), 0.25, accuracy: 0.0001)

        timer.pause(at: t0 + 20)
        XCTAssertTrue(timer.isPaused)
        XCTAssertEqual(timer.remaining(at: t0 + 500), 40, "time does not pass while paused")

        timer.resume(at: t0 + 500)
        XCTAssertEqual(timer.endDate, t0 + 540)
        XCTAssertFalse(timer.completeIfNeeded(at: t0 + 539))
        XCTAssertTrue(timer.completeIfNeeded(at: t0 + 541))
        XCTAssertFalse(timer.completeIfNeeded(at: t0 + 542), "completion fires once")
        XCTAssertEqual(timer.state, .finished)
        XCTAssertEqual(timer.remaining(at: t0 + 600), 0)

        timer.reset()
        XCTAssertEqual(timer.state, .idle)
        XCTAssertEqual(timer.remaining(at: t0), 60)
    }

    func testCountdownSurvivesSleepBecauseItIsDateBased() {
        var timer = CountdownTimer(duration: 300)
        timer.start(at: t0)
        // The machine sleeps for an hour; on wake the first check completes the timer.
        XCTAssertTrue(timer.completeIfNeeded(at: t0 + 3600))
    }

    func testDurationClampingAndLocking() {
        XCTAssertEqual(CountdownTimer(duration: 0).duration, CountdownTimer.minimumDuration)
        XCTAssertEqual(CountdownTimer(duration: 10_000_000).duration, CountdownTimer.maximumDuration)

        var timer = CountdownTimer(duration: 60)
        timer.start(at: t0)
        timer.setDuration(120)
        XCTAssertEqual(timer.duration, 60, "duration is locked while active")
    }

    func testExtend() {
        var timer = CountdownTimer(duration: 60)
        timer.start(at: t0)
        timer.extend(by: 60, at: t0 + 10)
        XCTAssertEqual(timer.remaining(at: t0 + 10), 110)
        timer.extend(by: -500, at: t0 + 10)
        XCTAssertEqual(timer.remaining(at: t0 + 10), 1, accuracy: 0.001, "never extends into the past")

        timer.pause(at: t0 + 10)
        timer.extend(by: 30, at: t0 + 10)
        XCTAssertEqual(timer.remaining(at: t0 + 10), 31, accuracy: 0.001)

        var idle = CountdownTimer(duration: 60)
        idle.extend(by: 60, at: t0)
        XCTAssertEqual(idle.duration, 120)
    }

    func testCountdownCodableRoundTrip() throws {
        var timer = CountdownTimer(duration: 90)
        timer.start(at: t0)
        let data = try JSONEncoder().encode(timer)
        let decoded = try JSONDecoder().decode(CountdownTimer.self, from: data)
        XCTAssertEqual(decoded, timer)
    }

    func testStopwatch() {
        var watch = Stopwatch()
        XCTAssertEqual(watch.elapsed(at: t0), 0)
        watch.start(at: t0)
        XCTAssertEqual(watch.elapsed(at: t0 + 5), 5)
        watch.lap(at: t0 + 5)
        watch.pause(at: t0 + 7)
        XCTAssertEqual(watch.elapsed(at: t0 + 100), 7)
        watch.start(at: t0 + 100)
        XCTAssertEqual(watch.elapsed(at: t0 + 103), 10)
        watch.lap(at: t0 + 103)
        XCTAssertEqual(watch.laps, [5, 10])
        watch.reset()
        XCTAssertEqual(watch.state, .idle)
        XCTAssertTrue(watch.laps.isEmpty)
    }

    func testStopwatchLapLimit() {
        var watch = Stopwatch()
        watch.start(at: t0)
        for index in 0..<150 { watch.lap(at: t0 + Double(index)) }
        XCTAssertEqual(watch.laps.count, Stopwatch.maximumLaps)
        XCTAssertEqual(watch.laps.last, 149)
    }

    func testClockFormatting() {
        XCTAssertEqual(TimeFormatting.clock(0), "0:00")
        XCTAssertEqual(TimeFormatting.clock(5.9), "0:05")
        XCTAssertEqual(TimeFormatting.clock(5.1, roundingUp: true), "0:06")
        XCTAssertEqual(TimeFormatting.clock(65), "1:05")
        XCTAssertEqual(TimeFormatting.clock(3_725), "1:02:05")
        XCTAssertEqual(TimeFormatting.clock(-3), "0:00")
        XCTAssertEqual(TimeFormatting.clock(.infinity), "--:--")
    }

    func testStopwatchFormatting() {
        XCTAssertEqual(TimeFormatting.stopwatch(0), "00:00.00")
        XCTAssertEqual(TimeFormatting.stopwatch(61.257), "01:01.25")
        XCTAssertEqual(TimeFormatting.stopwatch(3_661.5, showHundredths: false), "1:01:01")
    }

    func testShortDuration() {
        XCTAssertEqual(TimeFormatting.shortDuration(45), "45 s")
        XCTAssertEqual(TimeFormatting.shortDuration(300), "5 min")
        XCTAssertEqual(TimeFormatting.shortDuration(330), "5 min 30 s")
        XCTAssertEqual(TimeFormatting.shortDuration(5_400), "1 h 30 min")
        XCTAssertEqual(TimeFormatting.shortDuration(7_200), "2 h")
    }

    func testPlaybackPositionInterpolation() {
        let playing = PlaybackPosition(elapsed: 10, timestamp: t0, rate: 1)
        XCTAssertEqual(playing.elapsed(at: t0 + 5, duration: 200), 15)
        XCTAssertEqual(playing.elapsed(at: t0 + 500, duration: 200), 200, "clamped to the duration")
        XCTAssertEqual(playing.elapsed(at: t0 - 5, duration: 200), 10, "clock skew never goes backwards")

        let paused = PlaybackPosition(elapsed: 10, timestamp: t0, rate: 0)
        XCTAssertEqual(paused.elapsed(at: t0 + 50, duration: nil), 10)
    }
}
