import Foundation
import Observation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp` (macOS 13+). The state lives
/// in the system's Login Items, so it is read back from there instead of
/// being stored in our settings.
@MainActor
@Observable
final class LaunchAtLoginService {
    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    init() {
        refresh()
    }

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    var statusDescription: String {
        switch status {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Waiting for approval"
        case .notRegistered: return "Off"
        case .notFound: return "Unavailable"
        @unknown default: return "Unknown"
        }
    }

    var statusMessage: String? {
        if let lastError { return lastError }
        switch status {
        case .requiresApproval:
            return "Allow AlcoveInspired in System Settings › General › Login Items."
        case .notFound:
            return "Install the app in the Applications folder to use this option."
        default:
            return nil
        }
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
