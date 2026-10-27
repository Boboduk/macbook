import Foundation

/// Stable identifier of an activity. Updates with the same identifier replace
/// the existing activity in place instead of opening a new one.
public struct ActivityID: Hashable, Codable, ExpressibleByStringLiteral, CustomStringConvertible, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public static let music: ActivityID = "music"
    public static let musicPeek: ActivityID = "music.peek"
    public static let timer: ActivityID = "timer"
    public static let timerFinished: ActivityID = "timer.finished"
    public static let volumeHUD: ActivityID = "hud.volume"
    public static let brightnessHUD: ActivityID = "hud.brightness"
    public static let outputDevice: ActivityID = "hud.output"
    public static let power: ActivityID = "power"
    public static let powerLow: ActivityID = "power.low"

    public static func notice(_ id: String) -> ActivityID { ActivityID("notice.\(id)") }
}

/// The module an activity belongs to. Used for filtering (a disabled module
/// ends all of its activities) and for choosing the view.
public enum ActivityKind: String, Codable, CaseIterable, Sendable {
    case music
    case timer
    case volume
    case brightness
    case power
    case notification
}

public struct ActivityPriority: RawRepresentable, Comparable, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let low = ActivityPriority(rawValue: 10)
    public static let normal = ActivityPriority(rawValue: 50)
    public static let high = ActivityPriority(rawValue: 80)
    public static let critical = ActivityPriority(rawValue: 100)

    public static func < (lhs: ActivityPriority, rhs: ActivityPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// How long an activity stays.
public enum ActivityLifetime: Equatable, Sendable {
    /// Long-running state (music playing, timer running). Shown in the compact
    /// island while nothing more urgent is on screen. Optionally ends by
    /// itself after `expiresAfter` seconds without updates.
    case live(expiresAfter: TimeInterval?)
    /// Temporary event (HUD, notification). Shown once for `duration` seconds,
    /// then the island returns to the previous state.
    case transient(duration: TimeInterval)

    public var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

/// Width of the "wings" left and right of the camera housing.
public enum WingSize: String, Codable, CaseIterable, Sendable {
    case narrow   // artwork + playback indicator
    case regular  // icon + short text (timer, battery)
    case wide     // icon + level bar (volume, brightness)
}

/// Where an activity is drawn when it is not inside the expanded island.
public enum ActivityStyle: Equatable, Sendable {
    /// Content beside the notch; the island keeps the notch height.
    case compact(WingSize)
    /// The island drops below the notch to show a title and a message.
    case banner
}

/// What happens when the same activity is updated while it is visible.
public enum ActivityUpdatePolicy: Equatable, Sendable {
    /// The display countdown restarts (HUDs: keep showing while keys are pressed).
    case restartTimer
    /// Only the content changes; the remaining time is kept.
    case keepTimer
}

public struct LevelPayload: Equatable, Sendable {
    public var value: Double
    public var isMuted: Bool
    public var detail: String?

    public init(value: Double, isMuted: Bool = false, detail: String? = nil) {
        self.value = min(max(value, 0), 1)
        self.isMuted = isMuted
        self.detail = detail
    }
}

public struct MessagePayload: Equatable, Sendable {
    /// SF Symbol name.
    public var symbol: String
    public var title: String
    public var body: String
    /// Tab opened when the user taps the banner.
    public var actionTab: IslandTab?

    public init(symbol: String, title: String, body: String, actionTab: IslandTab? = nil) {
        self.symbol = symbol
        self.title = title
        self.body = body
        self.actionTab = actionTab
    }
}

public struct TrackPayload: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var source: MusicSourceKind

    public init(title: String, artist: String, album: String, source: MusicSourceKind) {
        self.title = title
        self.artist = artist
        self.album = album
        self.source = source
    }
}

public enum ActivityPayload: Equatable, Sendable {
    case none
    case level(LevelPayload)
    case message(MessagePayload)
    case track(TrackPayload)
    case power(PowerState)
}

/// A unit of information the island can show.
///
/// Live activities (music, timer) describe *that* something is going on; the
/// views read the live details from the feature controllers. Transient
/// activities carry everything they need in `payload`.
public struct Activity: Identifiable, Equatable, Sendable {
    public var id: ActivityID
    public var kind: ActivityKind
    public var priority: ActivityPriority
    public var title: String
    public var subtitle: String
    public var style: ActivityStyle
    public var lifetime: ActivityLifetime
    public var updatePolicy: ActivityUpdatePolicy
    /// When a more important transient preempts this one: `true` puts it back
    /// into the queue (notifications), `false` drops it (stale HUD values).
    public var requeueOnPreempt: Bool
    public var payload: ActivityPayload
    /// Set by `ActivityManager` on first appearance.
    public var createdAt: Date
    /// Set by `ActivityManager` on every update.
    public var updatedAt: Date

    public init(
        id: ActivityID,
        kind: ActivityKind,
        priority: ActivityPriority = .normal,
        title: String = "",
        subtitle: String = "",
        style: ActivityStyle,
        lifetime: ActivityLifetime,
        updatePolicy: ActivityUpdatePolicy = .restartTimer,
        requeueOnPreempt: Bool = false,
        payload: ActivityPayload = .none,
        createdAt: Date = Date(timeIntervalSinceReferenceDate: 0),
        updatedAt: Date = Date(timeIntervalSinceReferenceDate: 0)
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.title = title
        self.subtitle = subtitle
        self.style = style
        self.lifetime = lifetime
        self.updatePolicy = updatePolicy
        self.requeueOnPreempt = requeueOnPreempt
        self.payload = payload
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var transientDuration: TimeInterval? {
        if case let .transient(duration) = lifetime { return duration }
        return nil
    }
}
