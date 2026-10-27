import AppKit

/// Menu bar icon: the only always-visible entry point of an agent app
/// besides the island itself. Can be hidden in Settings › General (the
/// island's right-click menu offers the same commands).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menuProvider: () -> NSMenu
    private let menu = NSMenu()

    init(menuProvider: @escaping () -> NSMenu) {
        self.menuProvider = menuProvider
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = Self.makeIcon()
            button.toolTip = "AlcoveInspired"
            button.setAccessibilityLabel("AlcoveInspired")
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    /// A screen outline with the island at the top, drawn as a template image
    /// so it adapts to the menu bar appearance.
    private static func makeIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 14), flipped: false) { _ in
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 11), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.2
            NSColor.black.setStroke()
            screen.stroke()
            let island = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 8, width: 7, height: 3), xRadius: 1.5, yRadius: 1.5)
            NSColor.black.setFill()
            island.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    /// Rebuilds the menu each time it opens so check marks are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let fresh = menuProvider()
        for item in fresh.items {
            fresh.removeItem(item)
            menu.addItem(item)
        }
    }
}
