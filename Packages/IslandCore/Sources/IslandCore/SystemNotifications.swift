import Foundation

/// A notification delivered by any app, as recorded by macOS (usernoted).
public struct SystemNotification: Equatable, Sendable {
    /// Row id in the Notification Center database; increases monotonically.
    public var recordID: Int64
    public var bundleIdentifier: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var date: Date?

    public init(recordID: Int64, bundleIdentifier: String, title: String, subtitle: String, body: String, date: Date?) {
        self.recordID = recordID
        self.bundleIdentifier = bundleIdentifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.date = date
    }

    public var isEmpty: Bool { title.isEmpty && subtitle.isEmpty && body.isEmpty }
}

/// Decodes rows of the Notification Center database.
///
/// Each row of the `record` table stores the notification as a binary
/// property list: `{ app: <bundle id>, date: <seconds since 2001>,
/// req: { titl: <title>, subt: <subtitle>, body: <body>, … } }`.
public enum NotificationRecordParser {
    public static func parse(recordID: Int64, data: Data, fallbackBundleIdentifier: String? = nil, deliveredDate: Double? = nil) -> SystemNotification? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }
        let request = plist["req"] as? [String: Any] ?? [:]
        let bundleIdentifier = (plist["app"] as? String) ?? fallbackBundleIdentifier ?? ""
        guard !bundleIdentifier.isEmpty else { return nil }

        var date: Date?
        if let delivered = deliveredDate, delivered > 0 {
            date = Date(timeIntervalSinceReferenceDate: delivered)
        } else if let seconds = NowPlayingParser.number(plist["date"]) {
            date = Date(timeIntervalSinceReferenceDate: seconds)
        } else if let value = plist["date"] as? Date {
            date = value
        }

        let notification = SystemNotification(
            recordID: recordID,
            bundleIdentifier: bundleIdentifier,
            title: clean(request["titl"]),
            subtitle: clean(request["subt"]),
            body: clean(request["body"]),
            date: date
        )
        return notification.isEmpty ? nil : notification
    }

    private static func clean(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which mirrored notifications reach the island.
public enum SystemNotificationFilter {
    /// - Parameters:
    ///   - ownBundleIdentifier: the island app itself (its own banners are shown directly).
    ///   - mutedApps: bundle identifiers the user turned off.
    ///   - maximumAge: older records (delivered while the app was not running,
    ///     or a burst after granting access) are not replayed.
    public static func shouldShow(
        _ notification: SystemNotification,
        ownBundleIdentifier: String?,
        mutedApps: [String],
        now: Date,
        maximumAge: TimeInterval = 120
    ) -> Bool {
        if notification.isEmpty { return false }
        if let own = ownBundleIdentifier, notification.bundleIdentifier == own { return false }
        if mutedApps.contains(notification.bundleIdentifier) { return false }
        if let date = notification.date, now.timeIntervalSince(date) > maximumAge { return false }
        return true
    }
}

/// Finds the "close" action among the accessibility actions of a macOS
/// notification banner. Banners expose custom actions named like
/// `Name:Close\nTarget:0x0\nSelector:(null)`; the label is localized.
public enum BannerCloseAction {
    static let labels = [
        "close", "закрыть", "schließen", "fermer", "cerrar", "chiudi", "fechar",
        "sluiten", "stäng", "zamknij", "kapat", "关闭", "關閉", "閉じる", "닫기",
    ]

    public static func isClose(_ actionName: String) -> Bool {
        let label = displayLabel(of: actionName).lowercased()
        return labels.contains(label)
    }

    /// `Name:Close\nTarget:…` → `Close`; plain names are returned unchanged.
    public static func displayLabel(of actionName: String) -> String {
        guard actionName.hasPrefix("Name:") else { return actionName }
        let afterPrefix = actionName.dropFirst("Name:".count)
        let label = afterPrefix.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        return String(label).trimmingCharacters(in: .whitespaces)
    }
}
