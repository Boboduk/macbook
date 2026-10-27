import XCTest
@testable import IslandCore

final class IslandControllerTests: XCTestCase {
    private var scheduler: ManualScheduler!
    private var controller: IslandController!
    private var presentations: [IslandPresentation] = []

    override func setUp() {
        super.setUp()
        scheduler = ManualScheduler()
        controller = IslandController(scheduler: scheduler)
        presentations = []
        controller.onPresentationChange = { [unowned self] in self.presentations.append($0) }
    }

    private var activities: ActivityManager { controller.activities }

    func testStartsIdle() {
        XCTAssertEqual(controller.presentation, .idle(hovered: false))
    }

    func testHoverHighlightsThenExpandsAfterDelay() {
        controller.setHovering(true)
        XCTAssertEqual(controller.presentation, .idle(hovered: true))

        scheduler.advance(by: 0.29)
        XCTAssertFalse(controller.presentation.isExpanded)
        scheduler.advance(by: 0.02)
        XCTAssertTrue(controller.presentation.isExpanded)
        XCTAssertEqual(controller.expansion, .hover)
    }

    func testShortHoverDoesNotExpand() {
        controller.setHovering(true)
        scheduler.advance(by: 0.1)
        controller.setHovering(false)
        scheduler.advance(by: 5)
        XCTAssertEqual(controller.presentation, .idle(hovered: false))
    }

    func testHoverBehaviorHighlightNeverExpands() {
        controller.behavior.hover = .highlight
        controller.setHovering(true)
        scheduler.advance(by: 5)
        XCTAssertEqual(controller.presentation, .idle(hovered: true))
    }

    func testHoverBehaviorNoneHasNoVisualHover() {
        controller.behavior.hover = .none
        controller.setHovering(true)
        XCTAssertEqual(controller.presentation, .idle(hovered: false))
    }

    func testCollapseAfterCursorLeavesWithDelay() {
        controller.setHovering(true)
        scheduler.advance(by: 0.5)
        controller.setHovering(false)
        scheduler.advance(by: 0.4)
        XCTAssertTrue(controller.presentation.isExpanded, "collapse waits for the delay")
        controller.setHovering(true)
        scheduler.advance(by: 2)
        XCTAssertTrue(controller.presentation.isExpanded, "re-entering cancels the collapse")
        controller.setHovering(false)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(controller.presentation.isExpanded)
    }

    func testTapTogglesExpansion() {
        controller.behavior.hover = .highlight
        controller.setHovering(true)
        controller.tap()
        XCTAssertTrue(controller.presentation.isExpanded)
        XCTAssertEqual(controller.expansion, .tap)
        controller.tap()
        XCTAssertEqual(controller.presentation, .idle(hovered: true))
    }

    func testTapExpandedStaysWhenCollapseOnExitDisabled() {
        controller.behavior.collapseOnExit = false
        controller.tap()
        controller.setHovering(true)
        controller.setHovering(false)
        scheduler.advance(by: 5)
        XCTAssertTrue(controller.presentation.isExpanded)
        controller.tapOutside()
        XCTAssertFalse(controller.presentation.isExpanded)
    }

    func testPinnedIslandIgnoresExitTapAndOutsideClicks() {
        controller.setPinned(true)
        XCTAssertTrue(controller.presentation.isExpanded)
        controller.setHovering(true)
        controller.setHovering(false)
        scheduler.advance(by: 5)
        controller.tapOutside()
        controller.tap()
        guard case let .expanded(context) = controller.presentation else { return XCTFail("expected expanded") }
        XCTAssertTrue(context.isPinned)

        controller.setPinned(false)
        XCTAssertFalse(controller.presentation.isExpanded)
    }

    func testUnpinWhileHoveringCollapsesAfterLeaving() {
        controller.setPinned(true)
        controller.setHovering(true)
        controller.setPinned(false)
        XCTAssertTrue(controller.presentation.isExpanded)
        controller.setHovering(false)
        scheduler.advance(by: 0.5)
        XCTAssertFalse(controller.presentation.isExpanded)
    }

    func testLiveActivityShowsCompact() {
        activities.upsert(Fixtures.live(.music, kind: .music))
        guard case let .compact(activity, hovered) = controller.presentation else { return XCTFail() }
        XCTAssertEqual(activity.id, .music)
        XCTAssertFalse(hovered)

        controller.behavior.showLiveActivities = false
        XCTAssertEqual(controller.presentation, .idle(hovered: false))
    }

    func testTransientTemporarilyReplacesLiveActivity() {
        activities.upsert(Fixtures.live(.music, kind: .music))
        activities.upsert(Fixtures.hud(duration: 1.5))
        XCTAssertEqual(controller.presentation.focusedActivity?.id, .volumeHUD)
        scheduler.advance(by: 1.5)
        XCTAssertEqual(controller.presentation.focusedActivity?.id, .music, "returns to the previous activity")
    }

    func testBannerIsHeldWhileHoveredAndDoesNotAutoExpand() {
        activities.upsert(Fixtures.notice("n", duration: 2))
        controller.setHovering(true)
        scheduler.advance(by: 10)
        guard case .banner = controller.presentation else { return XCTFail("banner must stay while hovered") }
        controller.setHovering(false)
        scheduler.advance(by: 1.9)
        guard case .banner = controller.presentation else { return XCTFail("remaining time is kept after the hold") }
        scheduler.advance(by: 0.2)
        XCTAssertEqual(controller.presentation, .idle(hovered: false))
    }

    func testTapOnBannerDismissesAndOpensActionTab() {
        var activity = Fixtures.notice("done")
        activity.payload = .message(MessagePayload(symbol: "timer", title: "Done", body: "", actionTab: .timer))
        activities.upsert(activity)
        controller.tap()
        guard case let .expanded(context) = controller.presentation else { return XCTFail() }
        XCTAssertEqual(context.tab, .timer)
        XCTAssertNil(context.transient)
    }

    func testExpandedShowsTransientAsOverlayAndItExpires() {
        controller.tap()
        activities.upsert(Fixtures.hud(duration: 1.5))
        controller.setHovering(true)
        guard case let .expanded(context) = controller.presentation else { return XCTFail() }
        XCTAssertEqual(context.transient?.id, .volumeHUD)
        scheduler.advance(by: 1.6)
        guard case let .expanded(after) = controller.presentation else { return XCTFail() }
        XCTAssertNil(after.transient, "overlays are not held in the expanded island")
    }

    func testExpansionFocusesLiveActivityTab() {
        activities.upsert(Fixtures.live(.timer, kind: .timer, priority: .high))
        controller.tap()
        guard case let .expanded(context) = controller.presentation else { return XCTFail() }
        XCTAssertEqual(context.tab, .timer)
        controller.selectTab(.music)
        guard case let .expanded(changed) = controller.presentation else { return XCTFail() }
        XCTAssertEqual(changed.tab, .music)
    }

    func testUnavailableTabFallsBack() {
        controller.behavior.availableTabs = [.timer]
        controller.tap()
        guard case let .expanded(context) = controller.presentation else { return XCTFail() }
        XCTAssertEqual(context.tab, .timer)

        controller.behavior.availableTabs = []
        guard case let .expanded(empty) = controller.presentation else { return XCTFail() }
        XCTAssertNil(empty.tab)
    }

    func testSwipes() {
        XCTAssertEqual(controller.handleSwipe(.left), .none, "no music on screen")
        XCTAssertEqual(controller.handleSwipe(.down), .expanded)
        XCTAssertEqual(controller.handleSwipe(.down), .none)
        XCTAssertEqual(controller.handleSwipe(.right), .previousTrack, "music tab is the default page")
        XCTAssertEqual(controller.handleSwipe(.up), .collapsed)

        activities.upsert(Fixtures.notice("n"))
        XCTAssertEqual(controller.handleSwipe(.up), .dismissed)
        XCTAssertEqual(controller.presentation, .idle(hovered: false))

        activities.upsert(Fixtures.live(.music, kind: .music))
        XCTAssertEqual(controller.handleSwipe(.left), .nextTrack)

        controller.behavior.swipeGestures = false
        XCTAssertEqual(controller.handleSwipe(.down), .none)
    }

    func testInteractionPreventsCollapseAndExpiry() {
        controller.tap()
        controller.setHovering(true)
        controller.beginInteraction()
        controller.setHovering(false)
        scheduler.advance(by: 5)
        XCTAssertTrue(controller.presentation.isExpanded, "dragging a slider outside the island keeps it open")
        controller.endInteraction()
        scheduler.advance(by: 0.5)
        XCTAssertFalse(controller.presentation.isExpanded)
    }

    func testSuppressionHidesAndRestores() {
        activities.upsert(Fixtures.live(.music, kind: .music))
        controller.tap()
        controller.setSuppressed(true)
        XCTAssertEqual(controller.presentation, .hidden)
        controller.setSuppressed(false)
        guard case .compact = controller.presentation else { return XCTFail("returns collapsed, not expanded") }
    }

    func testPresentationCallbackOnlyOnChange() {
        controller.setHovering(true)
        let count = presentations.count
        controller.reevaluate()
        controller.behavior = controller.behavior
        XCTAssertEqual(presentations.count, count)
    }

    func testRapidEventsDoNotCauseChaoticReopening() {
        activities.upsert(Fixtures.live(.music, kind: .music))
        presentations.removeAll()
        for step in 0..<50 {
            activities.upsert(Fixtures.hud(value: Double(step) / 50))
            scheduler.advance(by: 0.05)
        }
        let kinds = Set(presentations.map(\.shapeKind))
        XCTAssertEqual(kinds, [.compact(.wide, hovered: false)], "the shape never collapses between updates")
        scheduler.advance(by: 2)
        XCTAssertEqual(controller.presentation.shapeKind, .compact(.narrow, hovered: false))
    }
}
