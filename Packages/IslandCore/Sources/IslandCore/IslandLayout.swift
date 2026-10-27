import Foundation
#if canImport(CoreGraphics)
// On Apple platforms CGRect/CGSize initializers and Equatable live in the
// CoreGraphics overlay, which Foundation no longer re-exports.
import CoreGraphics
#endif

/// Geometry of the camera housing on the display the island lives on.
public struct NotchMetrics: Equatable {
    /// Size of the physical notch, or of the synthetic one on displays without a notch.
    public var notchSize: CGSize
    public var hasNotch: Bool
    /// Width of the display, used to keep the island inside it.
    public var screenWidth: CGFloat

    public init(notchSize: CGSize, hasNotch: Bool, screenWidth: CGFloat) {
        self.notchSize = notchSize
        self.hasNotch = hasNotch
        self.screenWidth = screenWidth
    }

    /// Metrics for a display without a notch: a pill as tall as the menu bar.
    public static func synthetic(screenWidth: CGFloat, menuBarHeight: CGFloat) -> NotchMetrics {
        let height = max(22, min(menuBarHeight, 40))
        return NotchMetrics(
            notchSize: CGSize(width: 190, height: height),
            hasNotch: false,
            screenWidth: screenWidth
        )
    }

    /// Reasonable default (14" MacBook Pro) for previews and tests.
    public static let preview = NotchMetrics(
        notchSize: CGSize(width: 185, height: 32),
        hasNotch: true,
        screenWidth: 1512
    )
}

public struct IslandLayoutConfig: Equatable {
    /// Overall size multiplier (settings: compact / standard / large).
    public var scale: CGFloat
    /// Bottom corner radius of the expanded island.
    public var expandedCornerRadius: CGFloat
    /// On displays without a notch, show the idle pill (otherwise invisible until needed).
    public var fallbackIdleVisible: Bool

    public init(scale: CGFloat = 1, expandedCornerRadius: CGFloat = 24, fallbackIdleVisible: Bool = true) {
        self.scale = scale
        self.expandedCornerRadius = expandedCornerRadius
        self.fallbackIdleVisible = fallbackIdleVisible
    }
}

/// Resolved geometry of the island shape for one presentation.
public struct IslandFrame: Equatable {
    public var size: CGSize
    /// Radius of the concave "ears" that join the island to the top screen edge.
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    public var isVisible: Bool

    public init(size: CGSize, topRadius: CGFloat, bottomRadius: CGFloat, isVisible: Bool = true) {
        self.size = size
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.isVisible = isVisible
    }
}

/// Pure size calculations. Every size derives from the measured notch, the
/// user's scale and the screen width — no fixed screen coordinates.
public enum IslandLayout {
    /// Free space around the largest island inside the panel (for the shadow).
    public static let shadowMargin: CGFloat = 28
    /// Minimum horizontal distance between the island and the screen edges.
    public static let screenEdgeMargin: CGFloat = 12

    public static func wingWidth(_ wing: WingSize, metrics: NotchMetrics, config: IslandLayoutConfig) -> CGFloat {
        let height = metrics.notchSize.height
        switch wing {
        case .narrow: return (height + 8) * config.scale
        case .regular: return max(height * 2, 66) * config.scale
        case .wide: return max(height * 3, 100) * config.scale
        }
    }

    public static func frame(for kind: IslandShapeKind, metrics: NotchMetrics, config: IslandLayoutConfig) -> IslandFrame {
        let notch = metrics.notchSize
        let scale = config.scale
        let notchRadius = min(10, notch.height / 3)
        let maxWidth = max(notch.width, metrics.screenWidth - 2 * screenEdgeMargin)

        func clampWidth(_ width: CGFloat) -> CGFloat { min(width, maxWidth) }

        switch kind {
        case .hidden:
            return IslandFrame(size: notch, topRadius: 0, bottomRadius: notchRadius, isVisible: false)

        case let .idle(hovered):
            let visible = metrics.hasNotch || config.fallbackIdleVisible || hovered
            guard hovered else {
                return IslandFrame(size: notch, topRadius: 0, bottomRadius: notchRadius, isVisible: visible)
            }
            let size = CGSize(width: clampWidth(notch.width + 18 * scale), height: notch.height + 4 * scale)
            return IslandFrame(size: size, topRadius: 6, bottomRadius: min(12, size.height / 2.6), isVisible: true)

        case let .compact(wing, hovered):
            let wingWidth = wingWidth(wing, metrics: metrics, config: config)
            let extra: CGFloat = hovered ? 10 * scale : 0
            let size = CGSize(
                width: clampWidth(notch.width + 2 * wingWidth + extra),
                height: notch.height + (hovered ? 3 * scale : 0)
            )
            return IslandFrame(size: size, topRadius: 6, bottomRadius: min(14, size.height / 2.4))

        case let .banner(hovered):
            let width = max(notch.width + 2 * 120 * scale, 360 * scale) + (hovered ? 10 * scale : 0)
            let size = CGSize(width: clampWidth(width), height: notch.height + 66 * scale + (hovered ? 3 * scale : 0))
            return IslandFrame(size: size, topRadius: 10, bottomRadius: min(22, config.expandedCornerRadius))

        case .expanded:
            let width = max(notch.width + 2 * 170 * scale, 500 * scale)
            let size = CGSize(width: clampWidth(width), height: notch.height + 150 * scale)
            return IslandFrame(size: size, topRadius: 12, bottomRadius: config.expandedCornerRadius)
        }
    }

    /// Every shape kind the island can take.
    public static var allShapeKinds: [IslandShapeKind] {
        var kinds: [IslandShapeKind] = [.hidden, .idle(hovered: false), .idle(hovered: true), .expanded]
        for wing in WingSize.allCases {
            kinds.append(.compact(wing, hovered: false))
            kinds.append(.compact(wing, hovered: true))
        }
        kinds.append(.banner(hovered: false))
        kinds.append(.banner(hovered: true))
        return kinds
    }

    /// Size of the (never resized) panel: the largest island plus shadow room.
    public static func panelSize(metrics: NotchMetrics, config: IslandLayoutConfig) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for kind in allShapeKinds {
            let size = frame(for: kind, metrics: metrics, config: config).size
            width = max(width, size.width)
            height = max(height, size.height)
        }
        return CGSize(
            width: (min(width + 2 * shadowMargin, metrics.screenWidth)).rounded(.up),
            height: (height + shadowMargin).rounded(.up)
        )
    }

    /// Rect of the island inside a panel of `panelSize`, in a coordinate space
    /// with the origin at the panel's *bottom-left* corner (AppKit convention).
    public static func islandRect(size: CGSize, inPanelOfSize panelSize: CGSize) -> CGRect {
        CGRect(
            x: (panelSize.width - size.width) / 2,
            y: panelSize.height - size.height,
            width: size.width,
            height: size.height
        )
    }
}
