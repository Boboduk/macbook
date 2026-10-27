import AppKit
import IslandCore
import SwiftUI

/// Owns the island panel for the whole app lifetime: creates it once, keeps it
/// positioned at the notch of the right display, routes mouse input, and makes
/// the transparent part of the panel click-through.
@MainActor
final class IslandWindowController {
    private let coordinator: IslandCoordinator
    private let settings: SettingsStore
    private let panel: IslandPanel
    private let hostingView: IslandHostingView<IslandRootView>
    private let mouseTracker = MouseTracker()
    private let displayObserver = DisplayObserver()
    private var scrollRecognizer = ScrollGestureRecognizer()
    private weak var screen: NSScreen?

    /// Extra hover margin around the visible island, in points.
    private let hoverMargin: CGFloat = 4

    /// Called after wake from sleep and when the user session becomes active
    /// again (unlock, fast user switching).
    var onWake: (() -> Void)?

    var contextMenuProvider: (() -> NSMenu?)? {
        get { hostingView.contextMenuProvider }
        set { hostingView.contextMenuProvider = newValue }
    }

    init(coordinator: IslandCoordinator, settings: SettingsStore, rootView: IslandRootView) {
        self.coordinator = coordinator
        self.settings = settings
        self.panel = IslandPanel(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        self.hostingView = IslandHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
    }

    func start() {
        hostingView.onScroll = { [weak self] event in self?.handleScroll(event) }
        hostingView.onMouseActivity = { [weak self] in self?.mouseTracker.update() }

        mouseTracker.interactiveRect = { [weak self] in self?.interactiveRect() ?? .zero }
        mouseTracker.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        mouseTracker.onClickOutside = { [weak self] in self?.coordinator.tapOutside() }
        mouseTracker.start()

        coordinator.onGeometryChange = { [weak self] in self?.geometryChanged() }

        displayObserver.onChange = { [weak self] reason in self?.environmentChanged(reason) }
        displayObserver.start()

        reposition()
        panel.orderFrontRegardless()
    }

    func stop() {
        mouseTracker.stop()
        displayObserver.stop()
        panel.orderOut(nil)
    }

    /// Recomputes the target display, notch metrics and panel frame.
    func reposition() {
        guard let screen = ScreenPositioning.targetScreen(for: settings.settings.general.displayTarget) else {
            panel.orderOut(nil)
            return
        }
        self.screen = screen
        coordinator.updateMetrics(ScreenPositioning.metrics(for: screen))
        let frame = ScreenPositioning.panelFrame(for: screen, panelSize: coordinator.panelSize)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }
        updateFullscreenState()
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        mouseTracker.update()
    }

    // MARK: - Geometry

    /// Island rect in global screen coordinates (the *target* size: when the
    /// island grows the hit area grows at once, when it shrinks the hit area
    /// shrinks at once — so a collapsing island never swallows clicks).
    private func interactiveRect() -> CGRect {
        guard coordinator.presentation != .hidden else { return .zero }
        // An invisible idle pill (display without a notch) still has a hover
        // area, so the user can reveal it by moving to the top center.
        let frame = coordinator.islandFrame
        let island = IslandLayout.islandRect(size: frame.size, inPanelOfSize: panel.frame.size)
        var rect = island.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        rect = rect.insetBy(dx: -hoverMargin, dy: -hoverMargin)
        // The top edge always reaches the screen edge (cursor pushed against the top).
        rect.size.height += hoverMargin
        return rect
    }

    private func geometryChanged() {
        let expectedSize = coordinator.panelSize
        if let screen, panel.frame.size != expectedSize {
            panel.setFrame(ScreenPositioning.panelFrame(for: screen, panelSize: expectedSize), display: true)
        }
        mouseTracker.update()
        // Keep the click-through state in sync with the new island size.
        panel.ignoresMouseEvents = !mouseTracker.isInside
    }

    private func hoverChanged(_ inside: Bool) {
        panel.ignoresMouseEvents = !inside
        coordinator.hoverChanged(inside)
    }

    // MARK: - Environment

    private func environmentChanged(_ reason: DisplayObserver.Reason) {
        switch reason {
        case .screenParameters:
            reposition()
            panel.orderFrontRegardless()
        case .wake, .sessionActive:
            reposition()
            panel.orderFrontRegardless()
            onWake?()
        case .activeSpace, .appActivated:
            updateFullscreenState()
            panel.orderFrontRegardless()
        case .sessionInactive:
            coordinator.hoverChanged(false)
        }
    }

    private func updateFullscreenState() {
        guard settings.settings.general.hideInFullscreen, let screen else {
            coordinator.setHiddenForFullscreen(false)
            return
        }
        coordinator.setHiddenForFullscreen(FullscreenDetector.isFrontmostAppFullscreen(on: screen))
    }

    func settingsChanged(_ new: IslandSettings, old: IslandSettings) {
        if new.general.displayTarget != old.general.displayTarget
            || new.layoutConfig != old.layoutConfig
            || new.general.hideInFullscreen != old.general.hideInFullscreen {
            reposition()
        }
    }

    // MARK: - Gestures

    private func handleScroll(_ event: NSEvent) {
        let phase: ScrollGestureRecognizer.Phase
        if event.momentumPhase != [] {
            phase = .momentum
        } else if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            phase = .began
        } else if event.phase.contains(.changed) {
            phase = .changed
        } else if event.phase.contains(.ended) {
            phase = .ended
        } else if event.phase.contains(.cancelled) {
            phase = .cancelled
        } else {
            phase = event.hasPreciseScrollingDeltas ? .changed : .none
        }
        let direction = scrollRecognizer.handle(
            phase: phase,
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            isInverted: event.isDirectionInvertedFromDevice,
            timestamp: event.timestamp
        )
        if let direction {
            coordinator.swipe(direction)
            if settings.settings.general.hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }
}
