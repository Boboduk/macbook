import AppKit
import IslandCore

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }

    /// Rect of the camera housing in global screen coordinates, derived from
    /// the safe area and the two auxiliary menu bar areas left and right of it
    /// (macOS 12+). `nil` on displays without a notch.
    var notchRect: CGRect? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea
        else { return nil }
        let width = frame.width - left.width - right.width
        let height = safeAreaInsets.top
        guard width > 0, height > 0 else { return nil }
        return CGRect(x: frame.minX + left.width, y: frame.maxY - height, width: width, height: height)
    }

    var hasNotch: Bool { notchRect != nil }

    /// Height of the menu bar on this screen (0 if it is hidden).
    var menuBarHeight: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }
}

/// Places the island relative to the real display geometry.
@MainActor
enum ScreenPositioning {
    static func targetScreen(for target: DisplayTarget) -> NSScreen? {
        let screens = NSScreen.screens
        switch target {
        case .automatic:
            return screens.first(where: { $0.hasNotch && $0.isBuiltIn })
                ?? screens.first(where: { $0.hasNotch })
                ?? screens.first
        case .mainDisplay:
            // `screens[0]` is the primary display (the one with the menu bar
            // when "Displays have separate Spaces" is off).
            return screens.first
        }
    }

    static func metrics(for screen: NSScreen) -> NotchMetrics {
        if let notch = screen.notchRect {
            return NotchMetrics(notchSize: notch.size, hasNotch: true, screenWidth: screen.frame.width)
        }
        let menuBar = screen.menuBarHeight > 0 ? screen.menuBarHeight : NSStatusBar.system.thickness
        return .synthetic(screenWidth: screen.frame.width, menuBarHeight: menuBar)
    }

    /// Horizontal center of the island: the notch center, or the screen center.
    static func centerX(for screen: NSScreen) -> CGFloat {
        screen.notchRect?.midX ?? screen.frame.midX
    }

    /// Frame of the panel: top edge flush with the top of the screen,
    /// centered on the notch, clamped inside the screen horizontally.
    static func panelFrame(for screen: NSScreen, panelSize: CGSize) -> NSRect {
        let screenFrame = screen.frame
        var x = (centerX(for: screen) - panelSize.width / 2).rounded()
        x = min(max(x, screenFrame.minX), screenFrame.maxX - panelSize.width)
        return NSRect(
            x: x,
            y: screenFrame.maxY - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
    }
}
