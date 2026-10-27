import Foundation

/// Pages of the expanded island.
public enum IslandTab: String, Codable, CaseIterable, Identifiable, Sendable {
    case music
    case timer

    public var id: String { rawValue }
}

public struct ExpandedContext: Equatable, Sendable {
    /// Selected page; `nil` when no page-providing module is enabled.
    public var tab: IslandTab?
    public var availableTabs: [IslandTab]
    /// A HUD or notification shown on top of the expanded content.
    public var transient: Activity?
    public var isPinned: Bool

    public init(tab: IslandTab?, availableTabs: [IslandTab], transient: Activity?, isPinned: Bool) {
        self.tab = tab
        self.availableTabs = availableTabs
        self.transient = transient
        self.isPinned = isPinned
    }
}

/// Everything the UI needs to draw the island. Produced by `IslandController`.
public enum IslandPresentation: Equatable, Sendable {
    /// Suppressed (disabled, or hidden in a full-screen app).
    case hidden
    /// State A/B: plain black shape matching the notch.
    case idle(hovered: Bool)
    /// Live activity or HUD beside the notch.
    case compact(Activity, hovered: Bool)
    /// State D: the island drops below the notch for a message.
    case banner(Activity, hovered: Bool)
    /// State C/E: full panel.
    case expanded(ExpandedContext)

    public var shapeKind: IslandShapeKind {
        switch self {
        case .hidden:
            return .hidden
        case let .idle(hovered):
            return .idle(hovered: hovered)
        case let .compact(activity, hovered):
            if case let .compact(wing) = activity.style {
                return .compact(wing, hovered: hovered)
            }
            return .compact(.regular, hovered: hovered)
        case let .banner(_, hovered):
            return .banner(hovered: hovered)
        case .expanded:
            return .expanded
        }
    }

    /// The activity whose content is the main subject of the presentation.
    public var focusedActivity: Activity? {
        switch self {
        case .hidden, .idle:
            return nil
        case let .compact(activity, _), let .banner(activity, _):
            return activity
        case let .expanded(context):
            return context.transient
        }
    }

    public var isExpanded: Bool {
        if case .expanded = self { return true }
        return false
    }

    /// Identity of the visible content; when it changes the content view
    /// transitions (crossfade/blur), otherwise it updates in place.
    public var contentKey: String {
        switch self {
        case .hidden: return "hidden"
        case .idle: return "idle"
        case let .compact(activity, _): return "compact:\(activity.id.rawValue)"
        case let .banner(activity, _): return "banner:\(activity.id.rawValue)"
        case let .expanded(context): return "expanded:\(context.tab?.rawValue ?? "none")"
        }
    }
}

/// Geometry class of a presentation (what `IslandLayout` needs to size it).
public enum IslandShapeKind: Hashable, Sendable {
    case hidden
    case idle(hovered: Bool)
    case compact(WingSize, hovered: Bool)
    case banner(hovered: Bool)
    case expanded
}

public enum HoverBehavior: String, Codable, CaseIterable, Sendable {
    /// No reaction to hover.
    case none
    /// Slight enlargement only.
    case highlight
    /// Enlargement, then full expansion after the hover delay.
    case expand
}

public enum SwipeDirection: Equatable, Sendable {
    case up, down, left, right
}

/// What the app should do after a swipe was handled by `IslandController`.
public enum SwipeOutcome: Equatable, Sendable {
    case none
    case expanded
    case collapsed
    case dismissed
    case nextTrack
    case previousTrack
}
