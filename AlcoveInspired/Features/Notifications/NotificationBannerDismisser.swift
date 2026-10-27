import ApplicationServices
import AppKit
import IslandCore

/// Best-effort dismissal of the system's own notification banners, so a
/// mirrored notification is not shown twice (once by macOS, once by the
/// island).
///
/// There is no public API for this. The dismisser walks the accessibility
/// tree of the Notification Center UI process and performs the banner's
/// "close" action (or presses its close button). This is inherently fragile:
/// the layout of those windows is private and changes between macOS releases,
/// and it needs Accessibility access. It is therefore **opt-in and
/// experimental** — the reliable way to avoid duplicates is a Focus mode or
/// setting AlcoveInspired-unrelated apps to the "None" alert style. When the
/// tree does not match, the dismisser simply does nothing.
@MainActor
final class NotificationBannerDismisser {
    private let notificationCenterBundleID = "com.apple.notificationcenterui"

    /// Attempts to close any on-screen banners. Safe to call repeatedly.
    func dismissVisibleBanners(trusted: Bool) {
        guard trusted else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: notificationCenterBundleID).first
        else { return }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = copyChildren(application, attribute: kAXWindowsAttribute) else { return }
        for window in windows {
            close(window)
        }
    }

    private func close(_ element: AXUIElement) {
        // 1) A custom action whose label reads like "Close".
        var actionNames: CFArray?
        if AXUIElementCopyActionNames(element, &actionNames) == .success,
           let actions = actionNames as? [String] {
            for action in actions where BannerCloseAction.isClose(action) {
                AXUIElementPerformAction(element, action as CFString)
                return
            }
        }
        // 2) A standard close button.
        var button: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success,
           let button, CFGetTypeID(button) == AXUIElementGetTypeID() {
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            return
        }
        // 3) Recurse into children (the banner is often a nested group).
        if let children = copyChildren(element, attribute: kAXChildrenAttribute) {
            for child in children { close(child) }
        }
    }

    private func copyChildren(_ element: AXUIElement, attribute: String) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AXUIElement], !array.isEmpty
        else { return nil }
        return array
    }
}
