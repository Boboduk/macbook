import XCTest
@testable import IslandCore

final class LayoutTests: XCTestCase {
    private let metrics = NotchMetrics.preview
    private let config = IslandLayoutConfig()

    private func size(_ kind: IslandShapeKind, metrics: NotchMetrics? = nil, config: IslandLayoutConfig? = nil) -> CGSize {
        IslandLayout.frame(for: kind, metrics: metrics ?? self.metrics, config: config ?? self.config).size
    }

    func testIdleMatchesNotchExactly() {
        XCTAssertEqual(size(.idle(hovered: false)), metrics.notchSize)
        let frame = IslandLayout.frame(for: .idle(hovered: false), metrics: metrics, config: config)
        XCTAssertEqual(frame.topRadius, 0, "no ears at rest: the island hides behind the notch")
        XCTAssertTrue(frame.isVisible)
    }

    func testSizesGrowMonotonicallyWithState() {
        let idle = size(.idle(hovered: false))
        let hovered = size(.idle(hovered: true))
        let narrow = size(.compact(.narrow, hovered: false))
        let regular = size(.compact(.regular, hovered: false))
        let wide = size(.compact(.wide, hovered: false))
        let banner = size(.banner(hovered: false))
        let expanded = size(.expanded)

        XCTAssertGreaterThan(hovered.width, idle.width)
        XCTAssertGreaterThan(narrow.width, idle.width)
        XCTAssertGreaterThan(regular.width, narrow.width)
        XCTAssertGreaterThan(wide.width, regular.width)
        XCTAssertEqual(narrow.height, metrics.notchSize.height, "compact keeps the notch height")
        XCTAssertGreaterThan(banner.height, metrics.notchSize.height)
        XCTAssertGreaterThan(expanded.height, banner.height)
        XCTAssertGreaterThanOrEqual(expanded.width, banner.width)
    }

    func testHoverOnCompactIsSubtle() {
        let normal = size(.compact(.narrow, hovered: false))
        let hovered = size(.compact(.narrow, hovered: true))
        XCTAssertLessThanOrEqual(hovered.width - normal.width, 12)
        XCTAssertLessThanOrEqual(hovered.height - normal.height, 4)
    }

    func testEverythingFitsInPanel() {
        for scale: CGFloat in [0.9, 1.0, 1.12] {
            let config = IslandLayoutConfig(scale: scale, expandedCornerRadius: 30)
            let panel = IslandLayout.panelSize(metrics: metrics, config: config)
            for kind in IslandLayout.allShapeKinds {
                let size = IslandLayout.frame(for: kind, metrics: metrics, config: config).size
                XCTAssertLessThanOrEqual(size.width, panel.width, "\(kind) at \(scale)")
                XCTAssertLessThanOrEqual(size.height, panel.height, "\(kind) at \(scale)")
            }
        }
    }

    func testNarrowScreenClampsWidth() {
        let narrowScreen = NotchMetrics(notchSize: CGSize(width: 180, height: 32), hasNotch: true, screenWidth: 420)
        let expanded = size(.expanded, metrics: narrowScreen)
        XCTAssertLessThanOrEqual(expanded.width, 420 - 2 * IslandLayout.screenEdgeMargin)
        let panel = IslandLayout.panelSize(metrics: narrowScreen, config: config)
        XCTAssertLessThanOrEqual(panel.width, 420)
    }

    func testScaleAffectsExpandedSize() {
        let small = size(.expanded, config: IslandLayoutConfig(scale: 0.9))
        let large = size(.expanded, config: IslandLayoutConfig(scale: 1.12))
        XCTAssertGreaterThan(large.width, small.width)
        XCTAssertGreaterThan(large.height, small.height)
    }

    func testCornerRadiusSettingApplies() {
        let frame = IslandLayout.frame(for: .expanded, metrics: metrics, config: IslandLayoutConfig(expandedCornerRadius: 31))
        XCTAssertEqual(frame.bottomRadius, 31)
    }

    func testFallbackWithoutNotch() {
        let synthetic = NotchMetrics.synthetic(screenWidth: 1920, menuBarHeight: 24)
        XCTAssertFalse(synthetic.hasNotch)
        XCTAssertEqual(synthetic.notchSize.height, 24)

        let hiddenIdle = IslandLayout.frame(for: .idle(hovered: false), metrics: synthetic, config: IslandLayoutConfig(fallbackIdleVisible: false))
        XCTAssertFalse(hiddenIdle.isVisible)
        let hoveredIdle = IslandLayout.frame(for: .idle(hovered: true), metrics: synthetic, config: IslandLayoutConfig(fallbackIdleVisible: false))
        XCTAssertTrue(hoveredIdle.isVisible, "hovering reveals the hidden pill")
        let visibleIdle = IslandLayout.frame(for: .idle(hovered: false), metrics: synthetic, config: IslandLayoutConfig(fallbackIdleVisible: true))
        XCTAssertTrue(visibleIdle.isVisible)
    }

    func testSyntheticHeightIsBounded() {
        XCTAssertEqual(NotchMetrics.synthetic(screenWidth: 1000, menuBarHeight: 0).notchSize.height, 22)
        XCTAssertEqual(NotchMetrics.synthetic(screenWidth: 1000, menuBarHeight: 80).notchSize.height, 40)
    }

    func testIslandRectIsTopCentered() {
        let rect = IslandLayout.islandRect(size: CGSize(width: 200, height: 40), inPanelOfSize: CGSize(width: 600, height: 240))
        XCTAssertEqual(rect, CGRect(x: 200, y: 200, width: 200, height: 40))
    }

    func testPresentationShapeKinds() {
        let hud = Fixtures.hud()
        XCTAssertEqual(IslandPresentation.compact(hud, hovered: true).shapeKind, .compact(.wide, hovered: true))
        var bannerStyled = hud
        bannerStyled.style = .banner
        XCTAssertEqual(IslandPresentation.compact(bannerStyled, hovered: false).shapeKind, .compact(.regular, hovered: false))
        XCTAssertEqual(IslandPresentation.banner(hud, hovered: false).shapeKind, .banner(hovered: false))
        XCTAssertEqual(IslandPresentation.hidden.contentKey, "hidden")
    }
}
