import XCTest
@testable import IslandCore

final class ActivityManagerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var manager: ActivityManager!
    private var changeCount = 0

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        manager = ActivityManager(scheduler: scheduler)
        changeCount = 0
        manager.onChange = { [unowned self] in self.changeCount += 1 }
    }

    func testTransientExpiresAfterDuration() {
        manager.upsert(Fixtures.hud(duration: 1.5))
        XCTAssertEqual(manager.currentTransient?.id, .volumeHUD)

        scheduler.advance(by: 1.4)
        XCTAssertNotNil(manager.currentTransient)

        scheduler.advance(by: 0.2)
        XCTAssertNil(manager.currentTransient)
    }

    func testSameIDUpdateKeepsIdentityAndRestartsTimer() {
        manager.upsert(Fixtures.hud(value: 0.1, duration: 1.5))
        let created = manager.currentTransient?.createdAt
        scheduler.advance(by: 1.0)
        manager.upsert(Fixtures.hud(value: 0.2, duration: 1.5))

        XCTAssertEqual(manager.currentTransient?.createdAt, created, "in-place update must not look like a new activity")
        XCTAssertEqual(manager.currentTransient?.payload, .level(LevelPayload(value: 0.2)))

        scheduler.advance(by: 1.0)
        XCTAssertNotNil(manager.currentTransient, "timer restarted by the update")
        scheduler.advance(by: 0.6)
        XCTAssertNil(manager.currentTransient)
    }

    func testKeepTimerPolicyDoesNotExtendDisplay() {
        manager.upsert(Fixtures.notice("a", duration: 4))
        scheduler.advance(by: 3)
        manager.upsert(Fixtures.notice("a", duration: 4))
        scheduler.advance(by: 1.1)
        XCTAssertNil(manager.currentTransient)
    }

    func testRapidUpdatesDoNotGrowQueue() {
        for step in 0..<200 {
            manager.upsert(Fixtures.hud(value: Double(step) / 200))
            scheduler.advance(by: 0.01)
        }
        XCTAssertEqual(manager.currentTransient?.id, .volumeHUD)
        XCTAssertTrue(manager.queuedActivities.isEmpty)
        XCTAssertEqual(scheduler.pendingCount, 1, "only one expiry timer may be pending")
    }

    func testLowerPriorityWaitsInQueue() {
        manager.upsert(Fixtures.hud(duration: 1.5))
        manager.upsert(Fixtures.notice("n1", priority: .normal, duration: 4))

        XCTAssertEqual(manager.currentTransient?.id, .volumeHUD)
        XCTAssertEqual(manager.queuedActivities.map(\.id), [.notice("n1")])

        scheduler.advance(by: 1.5)
        XCTAssertEqual(manager.currentTransient?.id, .notice("n1"))
        scheduler.advance(by: 4)
        XCTAssertNil(manager.currentTransient)
    }

    func testHigherPriorityPreemptsAndRequeuesNotification() {
        manager.upsert(Fixtures.notice("n1", priority: .normal, duration: 4))
        scheduler.advance(by: 1)
        manager.upsert(Fixtures.hud(duration: 1.5))

        XCTAssertEqual(manager.currentTransient?.id, .volumeHUD)
        XCTAssertEqual(manager.queuedActivities.map(\.id), [.notice("n1")])

        scheduler.advance(by: 1.5)
        XCTAssertEqual(manager.currentTransient?.id, .notice("n1"), "returns to the preempted notification")
        scheduler.advance(by: 2.9)
        XCTAssertNotNil(manager.currentTransient, "remaining time (3 s) is preserved")
        scheduler.advance(by: 0.2)
        XCTAssertNil(manager.currentTransient)
    }

    func testPreemptedHUDIsDropped() {
        manager.upsert(Fixtures.hud(duration: 1.5, priority: .normal))
        manager.upsert(Fixtures.notice("urgent", priority: .critical))
        XCTAssertEqual(manager.currentTransient?.id, .notice("urgent"))
        XCTAssertTrue(manager.queuedActivities.isEmpty)
    }

    func testQueueOrderIsPriorityThenFIFO() {
        manager.upsert(Fixtures.notice("first", priority: .critical, duration: 1))
        manager.upsert(Fixtures.notice("low", priority: .low))
        manager.upsert(Fixtures.notice("normal1", priority: .normal))
        manager.upsert(Fixtures.notice("normal2", priority: .normal))
        manager.upsert(Fixtures.notice("high", priority: .high))
        XCTAssertEqual(manager.queuedActivities.map(\.id.rawValue), ["notice.high", "notice.normal1", "notice.normal2", "notice.low"])
    }

    func testQueueIsBounded() {
        let manager = ActivityManager(scheduler: scheduler, configuration: .init(maxQueueLength: 3))
        manager.upsert(Fixtures.notice("visible", priority: .critical))
        for index in 0..<10 {
            manager.upsert(Fixtures.notice("n\(index)", priority: index == 9 ? .high : .normal))
        }
        XCTAssertEqual(manager.queuedActivities.count, 3)
        XCTAssertEqual(manager.queuedActivities.first?.id, .notice("n9"), "important items survive overflow")
    }

    func testQueuedItemIsUpdatedInPlace() {
        manager.upsert(Fixtures.notice("visible", priority: .critical))
        manager.upsert(Fixtures.notice("q", priority: .low))
        manager.upsert(Fixtures.notice("q", priority: .high))
        XCTAssertEqual(manager.queuedActivities.count, 1)
        XCTAssertEqual(manager.queuedActivities.first?.priority, .high)
    }

    func testHoldPausesExpiryAndGivesGracePeriod() {
        manager.upsert(Fixtures.notice("n", duration: 2))
        scheduler.advance(by: 1.9)
        manager.setHold(true)
        scheduler.advance(by: 30)
        XCTAssertNotNil(manager.currentTransient, "held activity never expires")

        manager.setHold(false)
        scheduler.advance(by: 1.1)
        XCTAssertNotNil(manager.currentTransient, "at least the grace period remains")
        scheduler.advance(by: 0.2)
        XCTAssertNil(manager.currentTransient)
    }

    func testNewTransientWhileHeldWaitsForRelease() {
        manager.setHold(true)
        manager.upsert(Fixtures.hud(duration: 1.5))
        scheduler.advance(by: 10)
        XCTAssertNotNil(manager.currentTransient)
        manager.setHold(false)
        scheduler.advance(by: 1.5)
        XCTAssertNil(manager.currentTransient)
    }

    func testPrimaryLivePrefersPriorityThenRecency() {
        manager.upsert(Fixtures.live(.music, kind: .music, priority: .normal))
        XCTAssertEqual(manager.primaryLive?.id, .music)

        scheduler.advance(by: 1)
        manager.upsert(Fixtures.live(.timer, kind: .timer, priority: .high))
        XCTAssertEqual(manager.primaryLive?.id, .timer)

        manager.upsert(Fixtures.live(.timer, kind: .timer, priority: .normal))
        scheduler.advance(by: 1)
        manager.upsert(Fixtures.live(.music, kind: .music, priority: .normal))
        XCTAssertEqual(manager.primaryLive?.id, .music, "same priority: most recently updated wins")
    }

    func testLiveExpiryAndRenewal() {
        manager.upsert(Fixtures.live(.music, kind: .music, expiresAfter: 30))
        scheduler.advance(by: 20)
        manager.upsert(Fixtures.live(.music, kind: .music, expiresAfter: nil))
        scheduler.advance(by: 60)
        XCTAssertNotNil(manager.liveActivities[.music], "renewal without expiry cancels the old expiry")

        manager.upsert(Fixtures.live(.music, kind: .music, expiresAfter: 5))
        scheduler.advance(by: 5)
        XCTAssertNil(manager.liveActivities[.music])
    }

    func testEndRemovesFromEveryCollection() {
        manager.upsert(Fixtures.notice("a", priority: .high))
        manager.upsert(Fixtures.notice("b", priority: .normal))
        manager.upsert(Fixtures.live(.music, kind: .music))

        XCTAssertTrue(manager.end(.notice("a")))
        XCTAssertEqual(manager.currentTransient?.id, .notice("b"), "next queued item follows immediately")
        XCTAssertTrue(manager.end(.music))
        XCTAssertFalse(manager.end(.music))
    }

    func testEndAllKind() {
        manager.upsert(Fixtures.hud())
        manager.upsert(Fixtures.notice("x"))
        manager.upsert(Fixtures.live(.music, kind: .music))
        manager.endAll(kind: .volume)
        XCTAssertEqual(manager.currentTransient?.id, .notice("x"))
        manager.endAll(kind: .music)
        XCTAssertTrue(manager.liveActivities.isEmpty)
    }

    func testNoChangeNotificationForNoOps() {
        manager.end(.music)
        manager.setHold(false)
        manager.dismissCurrentTransient()
        XCTAssertEqual(changeCount, 0)
    }

    func testSwitchingLifetimeMovesActivity() {
        manager.upsert(Fixtures.live(.music, kind: .music))
        var transient = Fixtures.hud(.music, kind: .music)
        transient.style = .banner
        manager.upsert(transient)
        XCTAssertNil(manager.liveActivities[.music])
        XCTAssertEqual(manager.currentTransient?.id, .music)
    }
}
