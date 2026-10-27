import AppKit

/// Watches everything that can move, hide or invalidate the island:
/// display configuration changes, Space switches, app activation (full-screen
/// detection), sleep/wake and session switches (lock / unlock, fast user
/// switching).
@MainActor
final class DisplayObserver {
    enum Reason: String {
        case screenParameters
        case activeSpace
        case appActivated
        case wake
        case sessionActive
        case sessionInactive
    }

    var onChange: ((Reason) -> Void)?

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var pendingScreenChange: Task<Void, Never>?

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default

        observe(center, NSApplication.didChangeScreenParametersNotification) { observer in
            observer.screenParametersChanged()
        }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { observer in
            observer.onChange?(.activeSpace)
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { observer in
            observer.onChange?(.appActivated)
        }
        observe(workspace, NSWorkspace.didWakeNotification) { observer in
            observer.onChange?(.wake)
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { observer in
            observer.onChange?(.wake)
        }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { observer in
            observer.onChange?(.sessionActive)
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { observer in
            observer.onChange?(.sessionInactive)
        }
    }

    func stop() {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens.removeAll()
        pendingScreenChange?.cancel()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, handler: @escaping (DisplayObserver) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        tokens.append((center, token))
    }

    /// Display reconfiguration posts several notifications in a row
    /// (resolution, arrangement, menu bar); coalesce them.
    private func screenParametersChanged() {
        pendingScreenChange?.cancel()
        pendingScreenChange = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.onChange?(.screenParameters)
        }
    }
}
