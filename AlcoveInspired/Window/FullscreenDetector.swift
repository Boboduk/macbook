import AppKit

/// Detects whether the frontmost app shows a full-screen window on a screen.
///
/// macOS has no public "is this Space full screen" API. A full-screen window
/// is a normal-layer (0) window whose bounds equal the whole display (a zoomed
/// window stops below the menu bar). Window bounds and layers are available
/// from `CGWindowListCopyWindowInfo` without the Screen Recording permission
/// (only window titles are restricted). The check runs on Space switches and
/// app activation only, never periodically.
@MainActor
enum FullscreenDetector {
    static func isFrontmostAppFullscreen(on screen: NSScreen) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return false }
        let pid = frontmost.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let target = cgRect(for: screen)
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? Int, owner == Int(pid),
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { continue }
            if abs(bounds.minX - target.minX) < 1, abs(bounds.minY - target.minY) < 1,
               abs(bounds.width - target.width) < 1, abs(bounds.height - target.height) < 1 {
                return true
            }
        }
        return false
    }

    /// Converts an AppKit screen frame (origin bottom-left of the primary
    /// display) into Quartz window coordinates (origin top-left).
    private static func cgRect(for screen: NSScreen) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let frame = screen.frame
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
