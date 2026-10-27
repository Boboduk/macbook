import AppKit
import IslandCore
import UserNotifications

/// Notifications of the app itself.
///
/// * Island banners for internal events (`post(_:)`), routed through the
///   activity manager like every other activity.
/// * System notifications (`UNUserNotificationCenter`) for the timer, so the
///   end of a countdown is visible even when the island is hidden. They are
///   scheduled for the end date when the countdown starts, so they arrive on
///   time even if the app is busy.
///
/// Other apps' notifications are not available to third-party apps through
/// any public API and are therefore not shown.
@MainActor
final class NotificationService {
    var onEvent: ((IslandEvent) -> Void)?

    private let permissions: PermissionService
    private let delegate = ForegroundPresenter()
    private var settings: IslandSettings.Timer
    private static let timerRequestID = "io.github.boboduk.AlcoveInspired.timer"

    init(permissions: PermissionService, timerSettings: IslandSettings.Timer) {
        self.permissions = permissions
        self.settings = timerSettings
    }

    func start() {
        guard PermissionService.canUseUserNotifications else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    func apply(timerSettings new: IslandSettings.Timer) {
        let turnedOn = new.systemNotification && !settings.systemNotification
        settings = new
        if turnedOn, permissions.notifications == .notDetermined {
            permissions.requestNotifications()
        }
        if !new.systemNotification {
            cancelTimerNotification()
        }
    }

    /// Shows an island banner.
    func post(_ notice: Notice) {
        onEvent?(.notice(notice))
    }

    // MARK: - Timer

    /// Schedules (or cancels, with `nil`) the system notification for the
    /// countdown's end date. Asks for permission the first time it is needed.
    func scheduleTimerNotification(at endDate: Date?) {
        guard PermissionService.canUseUserNotifications else { return }
        cancelTimerNotification()
        guard settings.isEnabled, settings.systemNotification, let endDate else { return }
        let interval = endDate.timeIntervalSinceNow
        guard interval > 0.5 else { return }

        let schedule = {
            let content = UNMutableNotificationContent()
            content.title = "Timer"
            content.body = "Time is up."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, endDate.timeIntervalSinceNow), repeats: false)
            let request = UNNotificationRequest(identifier: Self.timerRequestID, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request) { _ in }
        }
        switch permissions.notifications {
        case .granted:
            schedule()
        case .notDetermined:
            permissions.requestNotifications { granted in
                if granted { schedule() }
            }
        case .denied, .unavailable:
            break
        }
    }

    func cancelTimerNotification() {
        guard PermissionService.canUseUserNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.timerRequestID])
    }

    /// Plays the completion sound inside the app (independent of the system
    /// notification, which the user may have silenced).
    func playTimerSound() {
        guard settings.playSound else { return }
        (NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Ping")))?.play()
    }
}

/// Shows notifications as banners even while the app is frontmost (e.g. the
/// settings window is open). Stateless, so it needs no actor isolation.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
