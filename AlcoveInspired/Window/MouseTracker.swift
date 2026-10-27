import AppKit

/// Decides whether the cursor is over the island and reports clicks outside.
///
/// Uses event monitors instead of polling: a global monitor sees movement
/// while other apps receive the events (no permission is needed for mouse
/// events), a local monitor sees movement over our own panel. Work per event
/// is a single rectangle test.
@MainActor
final class MouseTracker {
    /// Interactive area in global screen coordinates.
    var interactiveRect: () -> CGRect = { .zero }
    var onHoverChange: ((Bool) -> Void)?
    var onClickOutside: (() -> Void)?

    private(set) var isInside = false
    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .mouseEntered, .mouseExited]

        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.update() }
            return event
        }) {
            monitors.append(local)
        }
        if let globalClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClick() }
        }) {
            monitors.append(globalClicks)
        }
        if let localClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleClick() }
            return event
        }) {
            monitors.append(localClicks)
        }
        update()
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }

    /// Re-checks the cursor position (also called when the island changes size).
    func update() {
        let inside = interactiveRect().contains(NSEvent.mouseLocation)
        guard inside != isInside else { return }
        isInside = inside
        onHoverChange?(inside)
    }

    private func handleClick() {
        if !interactiveRect().contains(NSEvent.mouseLocation) {
            onClickOutside?()
        }
    }
}
