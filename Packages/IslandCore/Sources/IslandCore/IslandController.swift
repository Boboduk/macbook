import Foundation

/// The island's interaction state machine.
///
/// Inputs: hover, taps, swipes, pinning, slider interactions, suppression
/// (full screen / disabled) and the `ActivityManager` contents.
/// Output: a single `IslandPresentation`, re-evaluated after every input.
///
/// ```
///            hover (delay)        cursor leaves (delay)
///   idle ───────────────▶ expanded ────────────────▶ idle / compact / banner
///    │  ▲      tap             ▲  │ tap, swipe up, click outside
///    │  └──────────────────────┘  │
///    └─ live activity ▶ compact   └─ pinned: stays until unpinned
/// ```
public final class IslandController {
    public struct Behavior: Equatable {
        public var hover: HoverBehavior
        public var hoverExpandDelay: TimeInterval
        public var collapseDelay: TimeInterval
        /// Collapse a tap-expanded island when the cursor leaves it.
        public var collapseOnExit: Bool
        public var showLiveActivities: Bool
        public var swipeGestures: Bool
        public var availableTabs: [IslandTab]

        public init(
            hover: HoverBehavior = .expand,
            hoverExpandDelay: TimeInterval = 0.3,
            collapseDelay: TimeInterval = 0.45,
            collapseOnExit: Bool = true,
            showLiveActivities: Bool = true,
            swipeGestures: Bool = true,
            availableTabs: [IslandTab] = IslandTab.allCases
        ) {
            self.hover = hover
            self.hoverExpandDelay = hoverExpandDelay
            self.collapseDelay = collapseDelay
            self.collapseOnExit = collapseOnExit
            self.showLiveActivities = showLiveActivities
            self.swipeGestures = swipeGestures
            self.availableTabs = availableTabs
        }
    }

    public enum ExpansionReason: Equatable {
        case tap, hover, gesture, programmatic
    }

    public let activities: ActivityManager
    public private(set) var presentation: IslandPresentation = .idle(hovered: false)
    public private(set) var isHovering = false
    public private(set) var expansion: ExpansionReason?
    public private(set) var isPinned = false
    public private(set) var isSuppressed = false
    public private(set) var selectedTab: IslandTab?

    public var behavior: Behavior {
        didSet {
            guard behavior != oldValue else { return }
            if behavior.hover != .expand { cancelHoverExpansion() }
            reevaluate()
        }
    }

    /// Called with the new presentation whenever it changes.
    public var onPresentationChange: ((IslandPresentation) -> Void)?

    private let scheduler: IslandScheduler
    private var hoverToken: SchedulerToken?
    private var collapseToken: SchedulerToken?
    private var interactionCount = 0

    public init(scheduler: IslandScheduler, activities: ActivityManager? = nil, behavior: Behavior = Behavior()) {
        self.scheduler = scheduler
        self.activities = activities ?? ActivityManager(scheduler: scheduler)
        self.behavior = behavior
        self.activities.onChange = { [weak self] in self?.reevaluate() }
        self.presentation = resolve()
    }

    public var isExpanded: Bool { expansion != nil || isPinned }
    public var isInteracting: Bool { interactionCount > 0 }

    // MARK: - Inputs

    public func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        if hovering {
            cancelCollapse()
            scheduleHoverExpansionIfNeeded()
        } else {
            cancelHoverExpansion()
            scheduleCollapseIfNeeded()
        }
        updateHold()
        reevaluate()
    }

    /// Click on the island background.
    public func tap() {
        if isPinned { return }
        if expansion == nil, let transient = activities.currentTransient, transient.style == .banner {
            var tab: IslandTab?
            if case let .message(message) = transient.payload { tab = message.actionTab }
            if transient.kind == .music { tab = .music }
            activities.end(transient.id)
            if let tab, behavior.availableTabs.contains(tab) {
                expand(tab: tab, reason: .tap)
            }
            return
        }
        if expansion != nil {
            collapseNow()
        } else {
            expand(tab: nil, reason: .tap)
        }
    }

    /// Click anywhere outside the island.
    public func tapOutside() {
        guard expansion != nil, !isPinned, interactionCount == 0 else { return }
        collapseNow()
    }

    public func expand(tab: IslandTab? = nil, reason: ExpansionReason = .programmatic) {
        cancelHoverExpansion()
        cancelCollapse()
        if expansion == nil {
            selectedTab = tab ?? preferredTab()
        } else if let tab {
            selectedTab = tab
        }
        expansion = reason
        updateHold()
        reevaluate()
    }

    /// Explicit collapse (menu command, swipe up). Also unpins.
    public func collapse() {
        isPinned = false
        collapseNow()
    }

    public func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        if pinned {
            cancelCollapse()
            if expansion == nil { expansion = .programmatic; selectedTab = preferredTab() }
        } else if !isHovering && interactionCount == 0 {
            expansion = nil
        }
        updateHold()
        reevaluate()
    }

    public func selectTab(_ tab: IslandTab) {
        guard behavior.availableTabs.contains(tab), selectedTab != tab else { return }
        selectedTab = tab
        reevaluate()
    }

    public func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        isSuppressed = suppressed
        if suppressed {
            cancelHoverExpansion()
            cancelCollapse()
            if !isPinned { expansion = nil }
            isHovering = false
            updateHold()
        }
        reevaluate()
    }

    /// Bracket long interactions (dragging a slider) so that nothing collapses
    /// or expires under the user's cursor.
    public func beginInteraction() {
        interactionCount += 1
        cancelCollapse()
        updateHold()
    }

    public func endInteraction() {
        guard interactionCount > 0 else { return }
        interactionCount -= 1
        if interactionCount == 0 && !isHovering {
            scheduleCollapseIfNeeded()
        }
        updateHold()
    }

    @discardableResult
    public func handleSwipe(_ direction: SwipeDirection) -> SwipeOutcome {
        guard behavior.swipeGestures, !isSuppressed else { return .none }
        switch direction {
        case .down:
            guard expansion == nil, !isPinned else { return .none }
            expand(tab: nil, reason: .gesture)
            return .expanded
        case .up:
            if expansion != nil, !isPinned {
                collapseNow()
                return .collapsed
            }
            if expansion == nil, let transient = activities.currentTransient {
                activities.end(transient.id)
                return .dismissed
            }
            return .none
        case .left, .right:
            guard isShowingMusic else { return .none }
            return direction == .left ? .nextTrack : .previousTrack
        }
    }

    /// Re-resolves the presentation (called automatically on every input).
    public func reevaluate() {
        let resolved = resolve()
        guard resolved != presentation else { return }
        presentation = resolved
        onPresentationChange?(resolved)
    }

    // MARK: - Resolution

    private func resolve() -> IslandPresentation {
        if isSuppressed { return .hidden }
        let transient = activities.currentTransient
        if expansion != nil || isPinned {
            let tabs = behavior.availableTabs
            var tab = selectedTab
            if tab == nil || !tabs.contains(tab!) { tab = preferredTab() }
            return .expanded(ExpandedContext(tab: tab, availableTabs: tabs, transient: transient, isPinned: isPinned))
        }
        if let transient {
            switch transient.style {
            case .banner: return .banner(transient, hovered: isHovering)
            case .compact: return .compact(transient, hovered: isHovering)
            }
        }
        if behavior.showLiveActivities, let live = activities.primaryLive {
            return .compact(live, hovered: isHovering)
        }
        return .idle(hovered: isHovering && behavior.hover != .none)
    }

    private func preferredTab() -> IslandTab? {
        let tabs = behavior.availableTabs
        if let live = activities.primaryLive {
            let tab: IslandTab? = live.kind == .timer ? .timer : (live.kind == .music ? .music : nil)
            if let tab, tabs.contains(tab) { return tab }
        }
        if let selectedTab, tabs.contains(selectedTab) { return selectedTab }
        return tabs.first
    }

    private var isShowingMusic: Bool {
        switch presentation {
        case let .compact(activity, _), let .banner(activity, _):
            return activity.kind == .music
        case let .expanded(context):
            return context.tab == .music
        case .hidden, .idle:
            return false
        }
    }

    // MARK: - Timers

    private func scheduleHoverExpansionIfNeeded() {
        guard behavior.hover == .expand, expansion == nil, !isPinned, !isSuppressed else { return }
        // A banner is being read: hovering holds it instead of expanding over it.
        if let transient = activities.currentTransient, transient.style == .banner { return }
        cancelHoverExpansion()
        hoverToken = scheduler.schedule(after: behavior.hoverExpandDelay) { [weak self] in
            guard let self else { return }
            self.hoverToken = nil
            guard self.isHovering, self.expansion == nil else { return }
            self.expand(tab: nil, reason: .hover)
        }
    }

    private func cancelHoverExpansion() {
        hoverToken?.cancel()
        hoverToken = nil
    }

    private func scheduleCollapseIfNeeded() {
        guard let reason = expansion, !isPinned, interactionCount == 0 else { return }
        guard reason == .hover || behavior.collapseOnExit else { return }
        cancelCollapse()
        collapseToken = scheduler.schedule(after: behavior.collapseDelay) { [weak self] in
            guard let self else { return }
            self.collapseToken = nil
            guard !self.isHovering, !self.isPinned, self.interactionCount == 0 else { return }
            self.collapseNow()
        }
    }

    private func cancelCollapse() {
        collapseToken?.cancel()
        collapseToken = nil
    }

    private func collapseNow() {
        cancelHoverExpansion()
        cancelCollapse()
        expansion = nil
        updateHold()
        reevaluate()
    }

    /// Transients stay while the user reads them in the collapsed island.
    /// In the expanded island they are only overlays and expire normally.
    private func updateHold() {
        let held = (isHovering || interactionCount > 0) && !isExpanded
        activities.setHold(held)
    }
}
