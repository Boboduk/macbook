import AppKit
import IslandCore
import Observation
import SwiftUI

/// Bridges the platform-independent `IslandController` to SwiftUI and AppKit.
///
/// * Publishes the current `IslandPresentation` (with an animation chosen
///   from the kind of transition) and the notch metrics.
/// * Receives user input from the views and the window controller.
/// * Is the single entry point for feature events (`post(_:)`).
@MainActor
@Observable
final class IslandCoordinator {
    private(set) var presentation: IslandPresentation
    private(set) var metrics: NotchMetrics = .preview
    private(set) var layoutConfig: IslandLayoutConfig
    private(set) var appearance: IslandSettings.Appearance

    @ObservationIgnored let controller: IslandController
    @ObservationIgnored let router: EventRouter
    @ObservationIgnored let log: DiagnosticsLog
    @ObservationIgnored private let scheduler: MainQueueScheduler

    /// Called after the island geometry (target frame) changed.
    @ObservationIgnored var onGeometryChange: (() -> Void)?
    /// Track commands produced by swipes.
    @ObservationIgnored var onSwipeOutcome: ((SwipeOutcome) -> Void)?

    init(settings: IslandSettings, log: DiagnosticsLog) {
        self.log = log
        let scheduler = MainQueueScheduler()
        self.scheduler = scheduler
        let controller = IslandController(scheduler: scheduler, behavior: settings.controllerBehavior)
        self.controller = controller
        self.router = EventRouter(activities: controller.activities, settings: settings, log: log)
        self.presentation = controller.presentation
        self.layoutConfig = settings.layoutConfig
        self.appearance = settings.appearance

        controller.onPresentationChange = { [weak self] presentation in
            self?.present(presentation)
        }
        if settings.general.isPinned {
            controller.setPinned(true)
        }
        isEnabled = settings.general.isEnabled
        controller.setSuppressed(!settings.general.isEnabled)
    }

    // MARK: - Derived geometry

    /// Target frame of the island for the current presentation.
    var islandFrame: IslandFrame {
        IslandLayout.frame(for: presentation.shapeKind, metrics: metrics, config: layoutConfig)
    }

    var panelSize: CGSize {
        IslandLayout.panelSize(metrics: metrics, config: layoutConfig)
    }

    /// Size of the content for a shape kind without hover enlargement, so the
    /// content does not reflow while the shape breathes on hover.
    func contentSize(for kind: IslandShapeKind) -> CGSize {
        let stable: IslandShapeKind
        switch kind {
        case .idle: stable = .idle(hovered: false)
        case let .compact(wing, _): stable = .compact(wing, hovered: false)
        case .banner: stable = .banner(hovered: false)
        case .hidden, .expanded: stable = kind
        }
        return IslandLayout.frame(for: stable, metrics: metrics, config: layoutConfig).size
    }

    func wingWidth(_ wing: WingSize) -> CGFloat {
        IslandLayout.wingWidth(wing, metrics: metrics, config: layoutConfig)
    }

    // MARK: - Configuration

    func apply(settings: IslandSettings) {
        router.update(settings: settings)
        controller.behavior = settings.controllerBehavior
        if controller.isPinned != settings.general.isPinned {
            controller.setPinned(settings.general.isPinned)
        }
        controller.setSuppressed(!settings.general.isEnabled || isHiddenForFullscreen)
        if layoutConfig != settings.layoutConfig {
            withAnimation(springAnimation(response: 0.35, damping: 0.85)) {
                layoutConfig = settings.layoutConfig
            }
            onGeometryChange?()
        }
        appearance = settings.appearance
        isEnabled = settings.general.isEnabled
    }

    func updateMetrics(_ newMetrics: NotchMetrics) {
        guard newMetrics != metrics else { return }
        metrics = newMetrics
        onGeometryChange?()
    }

    @ObservationIgnored private var isEnabled = true
    @ObservationIgnored private var isHiddenForFullscreen = false

    func setHiddenForFullscreen(_ hidden: Bool) {
        isHiddenForFullscreen = hidden
        controller.setSuppressed(!isEnabled || hidden)
    }

    // MARK: - Events

    func post(_ event: IslandEvent) {
        router.handle(event)
    }

    // MARK: - User input

    func hoverChanged(_ hovering: Bool) {
        controller.setHovering(hovering)
    }

    func tap() {
        controller.tap()
    }

    func tapOutside() {
        controller.tapOutside()
    }

    func swipe(_ direction: SwipeDirection) {
        let outcome = controller.handleSwipe(direction)
        if outcome != .none {
            onSwipeOutcome?(outcome)
        }
    }

    func toggleExpanded() {
        if controller.isExpanded {
            controller.collapse()
        } else {
            controller.expand(reason: .programmatic)
        }
    }

    func expand(tab: IslandTab?) {
        controller.expand(tab: tab, reason: .programmatic)
    }

    func selectTab(_ tab: IslandTab) {
        controller.selectTab(tab)
    }

    func setPinned(_ pinned: Bool) {
        controller.setPinned(pinned)
    }

    func dismissTransient() {
        controller.activities.dismissCurrentTransient()
    }

    func beginInteraction() {
        controller.beginInteraction()
    }

    func endInteraction() {
        controller.endInteraction()
    }

    // MARK: - Presentation & animation

    private func present(_ new: IslandPresentation) {
        let old = presentation
        let animation = transitionAnimation(from: old, to: new)
        if let animation {
            withAnimation(animation) { presentation = new }
        } else {
            presentation = new
        }
        if old.shapeKind != new.shapeKind {
            onGeometryChange?()
        }
    }

    /// Picks the spring for a transition. Growing uses a livelier spring with
    /// a little overshoot; shrinking settles without bounce; in-place content
    /// updates are not animated here (their views animate values themselves).
    private func transitionAnimation(from old: IslandPresentation, to new: IslandPresentation) -> Animation? {
        guard old.shapeKind != new.shapeKind || old.contentKey != new.contentKey else { return nil }
        let oldArea = area(of: old.shapeKind)
        let newArea = area(of: new.shapeKind)
        if newArea > oldArea * 1.5 {
            return springAnimation(response: 0.44, damping: 0.72)
        }
        if newArea < oldArea / 1.5 {
            return springAnimation(response: 0.38, damping: 0.92)
        }
        return springAnimation(response: 0.32, damping: 0.8)
    }

    private func area(of kind: IslandShapeKind) -> CGFloat {
        let size = IslandLayout.frame(for: kind, metrics: metrics, config: layoutConfig).size
        return max(1, size.width * size.height)
    }

    func springAnimation(response: Double, damping: Double) -> Animation {
        let speed = max(0.5, appearance.animationSpeed)
        return .spring(response: response / speed, dampingFraction: damping)
    }
}
