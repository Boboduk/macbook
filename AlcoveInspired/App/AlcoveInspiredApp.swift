import AppKit

/// Entry point. The app is a pure AppKit agent (`LSUIElement`): no Dock icon,
/// no main menu; the island panel, a status item and the settings window are
/// the whole UI.
@main
enum AlcoveInspiredMain {
    static func main() {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            let delegate = AppDelegate()
            application.delegate = delegate
            application.setActivationPolicy(.accessory)
            // `NSApplication.delegate` is weak; keep the delegate alive for the
            // lifetime of the run loop.
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}
