import AppKit
import IslandCore
import SwiftUI

/// Hosts the SwiftUI settings in a regular window, created once and reused.
/// While the window is open the app temporarily becomes a regular app so the
/// window is reachable with ⌘-Tab and gets keyboard focus.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow

    init(model: AppModel) {
        let hosting = NSHostingController(rootView: SettingsView().environment(model))
        hosting.sizingOptions = []
        window = NSWindow(contentViewController: hosting)
        window.title = "AlcoveInspired Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 720, height: 560))
        window.contentMinSize = NSSize(width: 640, height: 460)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.center()
        window.setFrameAutosaveName("AlcoveInspiredSettings")
        super.init()
        window.delegate = self
        applyTheme(model.settings.settings.appearance.settingsTheme)
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applyTheme(_ theme: ThemeOption) {
        switch theme {
        case .system: window.appearance = nil
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
