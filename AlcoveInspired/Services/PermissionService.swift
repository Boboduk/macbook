import AppKit
import ApplicationServices
import CoreServices
import IslandCore
import Observation
import UserNotifications

enum AutomationStatus: Equatable {
    case granted
    case denied
    case notDetermined
    /// The app is not running, so macOS cannot report the status yet.
    case appNotRunning
    case unknown(Int32)

    var title: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        case .appNotRunning: return "App not running"
        case let .unknown(code): return "Unknown (\(code))"
        }
    }
}

enum NotificationPermission: Equatable {
    case granted
    case denied
    case notDetermined
    case unavailable

    var title: String {
        switch self {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not requested"
        case .unavailable: return "Unavailable"
        }
    }
}

/// Reads and requests the privacy permissions the optional features need.
/// Nothing is requested at launch: each permission is asked for only when the
/// user turns on (or first uses) the feature that needs it.
@MainActor
@Observable
final class PermissionService {
    private(set) var isAccessibilityTrusted = false
    private(set) var automation: [MusicSourceKind: AutomationStatus] = [:]
    private(set) var notifications: NotificationPermission = .notDetermined

    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?
    @ObservationIgnored var onAccessibilityChange: ((Bool) -> Void)?

    /// `UNUserNotificationCenter` aborts in a process without a bundle
    /// identifier (e.g. `swift run`), so guard every use.
    static var canUseUserNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func start() {
        refreshAccessibility()
        refreshNotifications()
        for source in MusicSourceKind.scriptable {
            refreshAutomation(for: source)
        }
        // Posted by the system whenever the Accessibility list changes.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The trust value is updated shortly after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated {
                    self?.refreshAccessibility()
                }
            }
        }
    }

    func stop() {
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
        }
        accessibilityObserver = nil
    }

    func refreshAll() {
        refreshAccessibility()
        refreshNotifications()
        for source in MusicSourceKind.scriptable {
            refreshAutomation(for: source)
        }
    }

    // MARK: - Accessibility (media keys)

    func refreshAccessibility() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted
        onAccessibilityChange?(trusted)
    }

    /// Shows the system prompt that leads to System Settings › Privacy &
    /// Security › Accessibility.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Automation (Music, Spotify)

    func refreshAutomation(for source: MusicSourceKind, completion: ((AutomationStatus) -> Void)? = nil) {
        determineAutomation(for: source, ask: false, completion: completion)
    }

    /// Asks the user (system prompt) if the status is not determined yet.
    /// The target app must be running.
    func requestAutomation(for source: MusicSourceKind, completion: ((AutomationStatus) -> Void)? = nil) {
        determineAutomation(for: source, ask: true, completion: completion)
    }

    private func determineAutomation(for source: MusicSourceKind, ask: Bool, completion: ((AutomationStatus) -> Void)?) {
        let bundleID = source.bundleIdentifier
        // May block until the user answers the prompt: never on the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let status = Self.automationStatus(bundleIdentifier: bundleID, ask: ask)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.automation[source] = status
                    completion?(status)
                }
            }
        }
    }

    nonisolated private static func automationStatus(bundleIdentifier: String, ask: Bool) -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        guard let address = target.aeDesc else { return .unknown(-1) }
        let status = AEDeterminePermissionToAutomateTarget(address, AEType.wildcard, AEType.wildcard, ask)
        switch status {
        case noErr: return .granted
        case -1743: return .denied                // errAEEventNotPermitted
        case -1744: return .notDetermined         // errAEEventWouldRequireUserConsent
        case -600: return .appNotRunning          // procNotFound
        default: return .unknown(status)
        }
    }

    // MARK: - Notifications (timer completion)

    func refreshNotifications() {
        guard Self.canUseUserNotifications else {
            notifications = .unavailable
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch status {
                    case .authorized, .provisional: self.notifications = .granted
                    case .denied: self.notifications = .denied
                    case .notDetermined: self.notifications = .notDetermined
                    @unknown default: self.notifications = .notDetermined
                    }
                }
            }
        }
    }

    func requestNotifications(completion: ((Bool) -> Void)? = nil) {
        guard Self.canUseUserNotifications else {
            completion?(false)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.notifications = granted ? .granted : .denied
                    completion?(granted)
                }
            }
        }
    }

    // MARK: - System Settings

    enum PrivacyPane: String {
        case accessibility = "Privacy_Accessibility"
        case automation = "Privacy_Automation"
        case fullDiskAccess = "Privacy_AllFiles"
        case notifications = "Notifications"
    }

    func open(_ pane: PrivacyPane) {
        let urlString: String
        switch pane {
        case .notifications:
            urlString = "x-apple.systempreferences:com.apple.preference.notifications"
        case .accessibility, .automation, .fullDiskAccess:
            urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
