import AppKit
import IslandCore
import Observation

/// Mirrors other apps' notifications into the island.
///
/// Reads new records from the Notification Center database
/// (`NotificationDatabaseReader`, needs Full Disk Access), resolves the
/// sending app's name, drops its own and stale records, remembers which apps
/// have been seen (for the mute list in Settings) and forwards the rest as
/// `IslandEvent.systemNotification`. When the user opts in, it also asks the
/// system to dismiss its own banner so the notification is shown only once.
@MainActor
@Observable
final class SystemNotificationMirror {
    /// Bundle id + display name of an app that has sent a notification.
    struct SeenApp: Identifiable, Equatable {
        var bundleIdentifier: String
        var name: String
        var id: String { bundleIdentifier }
    }

    private(set) var hasFullDiskAccess = false
    /// Apps seen this session, most recent first (for the mute UI).
    private(set) var seenApps: [SeenApp] = []

    @ObservationIgnored var onEvent: ((IslandEvent) -> Void)?

    @ObservationIgnored private let reader = NotificationDatabaseReader()
    @ObservationIgnored private let dismisser = NotificationBannerDismisser()
    @ObservationIgnored private let directory = AppDirectory.shared
    @ObservationIgnored private let permissions: PermissionService
    @ObservationIgnored private var settings: IslandSettings.Notifications
    @ObservationIgnored private let ownBundleID = Bundle.main.bundleIdentifier
    @ObservationIgnored private var started = false

    private static let seenLimit = 50

    init(settings: IslandSettings.Notifications, permissions: PermissionService) {
        self.settings = settings
        self.permissions = permissions
        reader.onNotification = { [weak self] notification in
            self?.handle(notification)
        }
        reader.onAccessChange = { [weak self] granted in
            self?.hasFullDiskAccess = granted
        }
    }

    // MARK: - Lifecycle

    func apply(settings new: IslandSettings.Notifications) {
        let wasMirroring = isMirroringEnabled
        settings = new
        if isMirroringEnabled, !wasMirroring {
            start()
        } else if !isMirroringEnabled, wasMirroring {
            stop()
        }
    }

    private var isMirroringEnabled: Bool {
        settings.isEnabled && settings.mirrorSystemNotifications
    }

    func start() {
        guard isMirroringEnabled, !started else { return }
        started = true
        reader.start()
        hasFullDiskAccess = reader.hasFullDiskAccess
    }

    func stop() {
        guard started else { return }
        started = false
        reader.stop()
    }

    /// Re-checks Full Disk Access (after the user may have granted it).
    func refreshAccess() {
        guard started else { return }
        reader.refreshAccess()
        hasFullDiskAccess = reader.hasFullDiskAccess
    }

    // MARK: - Handling

    private func handle(_ notification: SystemNotification) {
        let name = directory.name(for: notification.bundleIdentifier)
        recordSeen(notification.bundleIdentifier, name: name)

        guard SystemNotificationFilter.shouldShow(
            notification,
            ownBundleIdentifier: ownBundleID,
            mutedApps: settings.mutedApps,
            now: Date()
        ) else { return }

        onEvent?(.systemNotification(notification, appName: name))

        if settings.dismissSystemBanners {
            let trusted = permissions.isAccessibilityTrusted
            // The system paints its banner a moment after writing the record.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.dismisser.dismissVisibleBanners(trusted: trusted)
            }
        }
    }

    private func recordSeen(_ bundleIdentifier: String, name: String) {
        guard !bundleIdentifier.isEmpty, bundleIdentifier != ownBundleID else { return }
        if let index = seenApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            let existing = seenApps.remove(at: index)
            seenApps.insert(existing, at: 0)
        } else {
            seenApps.insert(SeenApp(bundleIdentifier: bundleIdentifier, name: name), at: 0)
            if seenApps.count > Self.seenLimit { seenApps.removeLast() }
        }
    }
}
