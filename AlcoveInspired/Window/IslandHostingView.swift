import AppKit
import SwiftUI

/// `NSHostingView` with the event handling SwiftUI does not offer for a
/// non-activating panel:
/// * accepts the first click (the panel is never key),
/// * forwards trackpad / wheel scrolling for swipe gestures,
/// * shows an AppKit context menu on right click,
/// * keeps a tracking area so the app receives mouse movement over the panel
///   even while another app is active.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((NSEvent) -> Void)?
    var contextMenuProvider: (() -> NSMenu?)?
    var onMouseActivity: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func scrollWheel(with event: NSEvent) {
        if let onScroll {
            onScroll(event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onMouseActivity?()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onMouseActivity?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseActivity?()
    }
}
