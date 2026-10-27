import Foundation
@testable import IslandCore

enum Fixtures {
    static func hud(_ id: ActivityID = .volumeHUD, kind: ActivityKind = .volume, value: Double = 0.5, duration: TimeInterval = 1.5, priority: ActivityPriority = .high) -> Activity {
        Activity(
            id: id, kind: kind, priority: priority,
            style: .compact(.wide), lifetime: .transient(duration: duration),
            updatePolicy: .restartTimer, requeueOnPreempt: false,
            payload: .level(LevelPayload(value: value))
        )
    }

    static func notice(_ id: String, priority: ActivityPriority = .normal, duration: TimeInterval = 4) -> Activity {
        Activity(
            id: .notice(id), kind: .notification, priority: priority,
            title: id, style: .banner, lifetime: .transient(duration: duration),
            updatePolicy: .keepTimer, requeueOnPreempt: true,
            payload: .message(MessagePayload(symbol: "bell", title: id, body: ""))
        )
    }

    static func live(_ id: ActivityID, kind: ActivityKind, priority: ActivityPriority = .normal, expiresAfter: TimeInterval? = nil) -> Activity {
        Activity(id: id, kind: kind, priority: priority, style: .compact(.narrow), lifetime: .live(expiresAfter: expiresAfter))
    }
}
