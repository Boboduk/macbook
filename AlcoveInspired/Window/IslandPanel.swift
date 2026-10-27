import AppKit

/// The single, long-lived window that hosts the island.
///
/// Configuration and why:
/// * `.borderless` + `.nonactivatingPanel` — no frame, and clicks never
///   activate the app or steal focus from the app the user is working in.
/// * `level = .mainMenu + 3` — above the menu bar (24) and status items (25),
///   below pop-up menus (101) so menu bar menus still cover the island.
/// * `.canJoinAllSpaces` + `.stationary` — present on every Space and not
///   moved by Mission Control / Exposé.
/// * `.fullScreenAuxiliary` — allowed next to full-screen windows.
/// * `.ignoresCycle` — never part of ⌘` window cycling.
/// * Transparent background, no shadow — SwiftUI draws the island and its
///   shadow; everything else must be invisible.
/// * `ignoresMouseEvents` starts `true`; `IslandWindowController` turns it off
///   only while the cursor is over the island, so the rest of the panel never
///   blocks clicks on windows underneath.
final class IslandPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
        canHide = false
    }

    convenience init(frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }

    /// The panel never takes keyboard focus: the island has no text input and
    /// must not interrupt typing in the frontmost app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit normally keeps windows below the menu bar; the island must sit
    /// exactly at the top edge of the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
