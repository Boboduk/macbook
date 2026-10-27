import Foundation
import IslandCore
import SQLite3
import XCTest
@testable import AlcoveInspired

/// Integration tests for the system-wide now-playing and notification-mirror
/// features. They run inside the real app process (test host) on macOS.

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

@MainActor
final class NotificationDatabaseReaderTests: XCTestCase {
    /// Builds a minimal Notification Center database (the `app` and `record`
    /// tables the reader queries) at a temporary path.
    private func makeDatabase(records: [(recID: Int64, appID: Int64, blob: Data, delivered: Double?)],
                              apps: [(appID: Int64, identifier: String)]) throws -> String {
        let path = NSTemporaryDirectory() + "nc-\(UUID().uuidString).sqlite"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
        CREATE TABLE app (app_id INTEGER PRIMARY KEY, identifier TEXT);
        CREATE TABLE record (rec_id INTEGER PRIMARY KEY, app_id INTEGER, data BLOB, delivered_date REAL);
        """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        for app in apps {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO app (app_id, identifier) VALUES (?, ?)", -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_int64(statement, 1, app.appID)
            sqlite3_bind_text(statement, 2, app.identifier, -1, sqliteTransient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        for record in records {
            var statement: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "INSERT INTO record (rec_id, app_id, data, delivered_date) VALUES (?, ?, ?, ?)", -1, &statement, nil), SQLITE_OK)
            sqlite3_bind_int64(statement, 1, record.recID)
            sqlite3_bind_int64(statement, 2, record.appID)
            _ = record.blob.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), sqliteTransient) }
            if let delivered = record.delivered {
                sqlite3_bind_double(statement, 4, delivered)
            } else {
                sqlite3_bind_null(statement, 4)
            }
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return path
    }

    private func bplist(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    func testReadsNewRecordsAndHighWaterMark() throws {
        let first = try bplist(["app": "com.apple.MobileSMS", "req": ["titl": "Anna", "body": "Dinner at 7?"]])
        let second = try bplist(["req": ["titl": "Build finished"]]) // no "app" → use the join
        let path = try makeDatabase(
            records: [
                (recID: 10, appID: 1, blob: first, delivered: nil),
                (recID: 11, appID: 2, blob: second, delivered: 760_000_000),
            ],
            apps: [(appID: 1, identifier: "com.apple.MobileSMS"), (appID: 2, identifier: "com.apple.dt.Xcode")]
        )
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Start-up read reports the high-water mark and emits nothing.
        let startup = NotificationDatabaseReader.readRecords(path: path, sinceID: nil)
        XCTAssertTrue(startup.accessible)
        XCTAssertEqual(startup.maxID, 11)
        XCTAssertTrue(startup.notifications.isEmpty)

        // Reading from the beginning returns both, newest id as the max.
        let all = NotificationDatabaseReader.readRecords(path: path, sinceID: 0)
        XCTAssertEqual(all.maxID, 11)
        XCTAssertEqual(all.notifications.count, 2)
        XCTAssertEqual(all.notifications.first?.bundleIdentifier, "com.apple.MobileSMS")
        XCTAssertEqual(all.notifications.first?.title, "Anna")
        XCTAssertEqual(all.notifications.last?.bundleIdentifier, "com.apple.dt.Xcode")

        // Only records newer than the cursor are returned.
        let tail = NotificationDatabaseReader.readRecords(path: path, sinceID: 10)
        XCTAssertEqual(tail.notifications.map(\.recordID), [11])
    }

    func testMissingDatabaseIsNotAnAccessFailure() {
        let result = NotificationDatabaseReader.readRecords(path: NSTemporaryDirectory() + "does-not-exist.sqlite", sinceID: 0)
        XCTAssertTrue(result.accessible)
        XCTAssertTrue(result.notifications.isEmpty)
    }
}

@MainActor
final class MediaRemoteBridgeTests: XCTestCase {
    /// The bridge launches the perl-hosted helper and produces a message
    /// (`ready`, or `error` if MediaRemote/perl cannot cooperate on this
    /// machine) rather than hanging. Skipped where the helper is not embedded
    /// in the test host bundle.
    func testBridgeProducesAMessage() throws {
        let helper = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("libNowPlayingHelper.dylib").path
        try XCTSkipUnless(
            helper.map { FileManager.default.fileExists(atPath: $0) } ?? false,
            "NowPlayingHelper is not embedded in this test host"
        )
        let bridge = MediaRemoteBridge()
        let received = expectation(description: "a message from the helper")
        received.assertForOverFulfill = false
        bridge.onMessage = { _ in received.fulfill() }
        bridge.start()
        wait(for: [received], timeout: 20)
        bridge.stop()
    }
}

@MainActor
final class SystemNotificationMirrorTests: XCTestCase {
    /// Starting, toggling and stopping the mirror touches the real database
    /// path and FSEvents without crashing, whether or not Full Disk Access is
    /// granted on this machine.
    func testLifecycleIsSafeWithoutFullDiskAccess() {
        let permissions = PermissionService()
        var settings = IslandSettings.default.notifications
        let mirror = SystemNotificationMirror(settings: settings, permissions: permissions)

        mirror.start() // mirroring is off by default: a no-op
        XCTAssertTrue(mirror.seenApps.isEmpty)

        settings.mirrorSystemNotifications = true
        mirror.apply(settings: settings) // starts reading; must not crash
        mirror.refreshAccess()
        _ = mirror.hasFullDiskAccess
        mirror.stop()
    }
}
