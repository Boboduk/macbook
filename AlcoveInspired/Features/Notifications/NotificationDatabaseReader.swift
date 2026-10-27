import CoreServices
import Foundation
import IslandCore
import SQLite3
import os.log

/// Reads other apps' notifications from the Notification Center database.
///
/// macOS has no public API to observe the notifications of other apps. The
/// system does, however, record every delivered notification in a SQLite
/// database inside the per-user Darwin folder
/// (`…/com.apple.notificationcenter/db2/db`). Reading it requires the user to
/// grant **Full Disk Access** to AlcoveInspired. The database is watched with
/// FSEvents; each change triggers a query for rows newer than the last one
/// seen, which are decoded by `NotificationRecordParser`.
///
/// Only *new* notifications are emitted: at start the reader remembers the
/// current highest row id, so the backlog is never replayed, and
/// `SystemNotificationFilter` drops anything older than two minutes as a
/// second guard.
@MainActor
final class NotificationDatabaseReader {
    /// A new notification was recorded by the system.
    var onNotification: ((SystemNotification) -> Void)?
    /// Full Disk Access became available or was lost.
    var onAccessChange: ((Bool) -> Void)?

    private(set) var hasFullDiskAccess = false

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AlcoveInspired", category: "Notifications")
    private let databasePath: String?
    private let watchQueue = DispatchQueue(label: "io.github.boboduk.AlcoveInspired.ncwatch")

    private var stream: FSEventStreamRef?
    private var lastSeenID: Int64 = 0
    private var started = false

    init() {
        databasePath = Self.locateDatabase()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        // The first read sets the high-water mark and tells us whether Full
        // Disk Access is granted; it never emits the backlog.
        let result = Self.readRecords(path: databasePath, sinceID: nil)
        updateAccess(result.accessible)
        if let maxID = result.maxID { lastSeenID = maxID }
        if result.accessible { startWatching() }
    }

    func stop() {
        started = false
        stopWatching()
    }

    /// Re-checks access (e.g. after the user granted it) and starts watching.
    func refreshAccess() {
        guard started else { return }
        let result = Self.readRecords(path: databasePath, sinceID: nil)
        let wasAccessible = hasFullDiskAccess
        updateAccess(result.accessible)
        if result.accessible {
            if !wasAccessible, let maxID = result.maxID { lastSeenID = maxID }
            if stream == nil { startWatching() }
        } else {
            stopWatching()
        }
    }

    // MARK: - Reading

    private func poll() {
        guard started else { return }
        let result = Self.readRecords(path: databasePath, sinceID: lastSeenID)
        updateAccess(result.accessible)
        guard result.accessible else {
            stopWatching()
            return
        }
        for notification in result.notifications {
            onNotification?(notification)
        }
        if let maxID = result.maxID, maxID > lastSeenID {
            lastSeenID = maxID
        }
    }

    private func updateAccess(_ accessible: Bool) {
        guard accessible != hasFullDiskAccess else { return }
        hasFullDiskAccess = accessible
        onAccessChange?(accessible)
    }

    // MARK: - FSEvents

    private func startWatching() {
        guard stream == nil, let path = databasePath else { return }
        let directory = (path as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let reader = Unmanaged<NotificationDatabaseReader>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { reader.poll() } }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagFileEvents)
        ) else {
            log.error("could not create FSEventStream for the notification database")
            return
        }
        FSEventStreamSetDispatchQueue(stream, watchQueue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Database location

    /// `…/com.apple.notificationcenter/db2/db` under the per-user Darwin dir.
    private static func locateDatabase() -> String? {
        let length = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, length) > 0 else { return nil }
        let base = String(cString: buffer)
        return (base as NSString).appendingPathComponent("com.apple.notificationcenter/db2/db")
    }

    // MARK: - SQLite (runs synchronously; the database is tiny and indexed)

    struct ReadResult {
        var accessible: Bool
        var notifications: [SystemNotification]
        var maxID: Int64?
    }

    nonisolated static func readRecords(path: String?, sinceID: Int64?) -> ReadResult {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            // No database yet (a brand-new account) is not an access failure.
            return ReadResult(accessible: path != nil, notifications: [], maxID: nil)
        }

        var handle: OpaquePointer?
        // Read-only; SQLite reads the WAL from a private heap when it cannot
        // write the shared-memory file (which Full Disk Access allows).
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return ReadResult(accessible: false, notifications: [], maxID: nil)
        }
        defer { sqlite3_close(db) }

        if let sinceID {
            return query(db: db, sinceID: sinceID)
        }
        // Start-up: just find the current high-water mark.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(rec_id) FROM record", -1, &statement, nil) == SQLITE_OK else {
            // Table missing or unreadable: we could open the file, so access is
            // fine; treat as empty.
            return ReadResult(accessible: true, notifications: [], maxID: nil)
        }
        defer { sqlite3_finalize(statement) }
        var maxID: Int64?
        if sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL {
            maxID = sqlite3_column_int64(statement, 0)
        }
        return ReadResult(accessible: true, notifications: [], maxID: maxID)
    }

    nonisolated private static func query(db: OpaquePointer, sinceID: Int64) -> ReadResult {
        let sql = """
        SELECT record.rec_id, app.identifier, record.data, record.delivered_date
        FROM record LEFT JOIN app ON app.app_id = record.app_id
        WHERE record.rec_id > ?
        ORDER BY record.rec_id ASC
        LIMIT 50
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return ReadResult(accessible: true, notifications: [], maxID: nil)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, sinceID)

        var notifications: [SystemNotification] = []
        var maxID = sinceID
        while sqlite3_step(statement) == SQLITE_ROW {
            let recordID = sqlite3_column_int64(statement, 0)
            maxID = max(maxID, recordID)

            let bundleIdentifier = text(statement, 1)
            guard let blob = sqlite3_column_blob(statement, 2) else { continue }
            let length = Int(sqlite3_column_bytes(statement, 2))
            guard length > 0 else { continue }
            let data = Data(bytes: blob, count: length)
            let delivered = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)

            if let notification = NotificationRecordParser.parse(
                recordID: recordID,
                data: data,
                fallbackBundleIdentifier: bundleIdentifier,
                deliveredDate: delivered
            ) {
                notifications.append(notification)
            }
        }
        return ReadResult(accessible: true, notifications: notifications, maxID: maxID)
    }

    nonisolated private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: cString)
    }
}
