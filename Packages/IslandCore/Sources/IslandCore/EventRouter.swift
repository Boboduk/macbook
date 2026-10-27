import Foundation

/// An internal notification shown as a banner.
public struct Notice: Equatable, Sendable {
    public var id: String
    /// SF Symbol name.
    public var symbol: String
    public var title: String
    public var body: String
    public var priority: ActivityPriority
    /// Overrides the duration from the settings.
    public var duration: TimeInterval?
    public var actionTab: IslandTab?

    public init(
        id: String,
        symbol: String,
        title: String,
        body: String,
        priority: ActivityPriority = .normal,
        duration: TimeInterval? = nil,
        actionTab: IslandTab? = nil
    ) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.body = body
        self.priority = priority
        self.duration = duration
        self.actionTab = actionTab
    }
}

public enum TimerActivityMode: String, Equatable, Sendable {
    case countdown
    case stopwatch
}

/// Raw events produced by the feature modules.
public enum IslandEvent: Equatable, Sendable {
    case volumeChanged(level: Double, muted: Bool, device: String?)
    case brightnessChanged(level: Double)
    case outputDeviceChanged(name: String, isHeadphones: Bool)
    /// Current player state; `nil` when no supported player is active.
    case nowPlaying(NowPlayingSnapshot?)
    case trackChanged(TrackInfo, source: MusicSourceKind)
    /// `nil` when neither the countdown nor the stopwatch is active.
    case timerActive(TimerActivityMode?, isRunning: Bool)
    case timerFinished(title: String, body: String)
    case power(PowerState, PowerChange)
    case notice(Notice)
}

/// Translates module events into activities, applying the user's settings
/// (enabled modules, durations, HUD style). Owns no timers itself — all
/// timing is delegated to `ActivityManager`.
public final class EventRouter {
    public private(set) var settings: IslandSettings
    public let activities: ActivityManager
    public let log: DiagnosticsLog?

    public init(activities: ActivityManager, settings: IslandSettings, log: DiagnosticsLog? = nil) {
        self.activities = activities
        self.settings = settings
        self.log = log
    }

    /// Applies new settings and ends activities of modules that were turned off.
    public func update(settings newSettings: IslandSettings) {
        let old = settings
        settings = newSettings
        for kind in ActivityKind.allCases where old.isModuleEnabled(kind) && !newSettings.isModuleEnabled(kind) {
            activities.endAll(kind: kind)
        }
        // Live activities hidden from the compact island are ended; the app
        // republishes the current state when they are turned back on.
        if !newSettings.music.showCompact { activities.end(.music) }
        if !newSettings.timer.showCompact { activities.end(.timer) }
    }

    public func handle(_ event: IslandEvent) {
        switch event {
        case let .volumeChanged(level, muted, device):
            guard settings.volume.hud.isEnabled else { return dropped("volume") }
            log?.append("hud", "volume \(Int((level * 100).rounded()))%\(muted ? " muted" : "")")
            activities.upsert(levelActivity(
                id: .volumeHUD, kind: .volume, hud: settings.volume.hud,
                payload: LevelPayload(value: level, isMuted: muted, detail: device)
            ))

        case let .brightnessChanged(level):
            guard settings.brightness.isEnabled else { return dropped("brightness") }
            log?.append("hud", "brightness \(Int((level * 100).rounded()))%")
            activities.upsert(levelActivity(
                id: .brightnessHUD, kind: .brightness, hud: settings.brightness,
                payload: LevelPayload(value: level)
            ))

        case let .outputDeviceChanged(name, isHeadphones):
            guard settings.volume.hud.isEnabled, settings.volume.showOutputDeviceChanges else { return dropped("output") }
            log?.append("hud", "output device changed")
            activities.upsert(Activity(
                id: .outputDevice, kind: .volume, priority: .normal,
                title: name, subtitle: "Audio output",
                style: .banner, lifetime: .transient(duration: 2.5),
                payload: .message(MessagePayload(
                    symbol: isHeadphones ? "headphones" : "hifispeaker.fill",
                    title: name, body: "Audio output"
                ))
            ))

        case let .nowPlaying(snapshot):
            handleNowPlaying(snapshot)

        case let .trackChanged(track, source):
            guard settings.music.isEnabled, settings.music.peekOnTrackChange else { return }
            log?.append("music", "track changed (\(source.displayName))")
            activities.upsert(Activity(
                id: .musicPeek, kind: .music, priority: .low,
                title: track.title, subtitle: track.artist,
                style: .banner, lifetime: .transient(duration: 3),
                payload: .track(TrackPayload(title: track.title, artist: track.artist, album: track.album, source: source))
            ))

        case let .timerActive(mode, isRunning):
            guard settings.timer.isEnabled, let mode else {
                activities.end(.timer)
                return
            }
            guard settings.timer.showCompact else {
                activities.end(.timer)
                return
            }
            activities.upsert(Activity(
                id: .timer, kind: .timer, priority: isRunning ? .high : .normal,
                title: mode == .countdown ? "Timer" : "Stopwatch",
                style: .compact(.regular), lifetime: .live(expiresAfter: nil)
            ))

        case let .timerFinished(title, body):
            guard settings.timer.isEnabled else { return }
            log?.append("timer", "finished")
            activities.upsert(Activity(
                id: .timerFinished, kind: .timer, priority: .critical,
                title: title, subtitle: body,
                style: .banner, lifetime: .transient(duration: 8),
                updatePolicy: .restartTimer, requeueOnPreempt: true,
                payload: .message(MessagePayload(symbol: "timer", title: title, body: body, actionTab: .timer))
            ))

        case let .power(state, change):
            handlePower(state, change)

        case let .notice(notice):
            guard settings.notifications.isEnabled else { return dropped("notice") }
            log?.append("notice", notice.id)
            activities.upsert(Activity(
                id: .notice(notice.id), kind: .notification, priority: notice.priority,
                title: notice.title, subtitle: notice.body,
                style: .banner,
                lifetime: .transient(duration: notice.duration ?? settings.notifications.duration),
                updatePolicy: .keepTimer, requeueOnPreempt: true,
                payload: .message(MessagePayload(symbol: notice.symbol, title: notice.title, body: notice.body, actionTab: notice.actionTab))
            ))
        }
    }

    // MARK: - Helpers

    private func levelActivity(id: ActivityID, kind: ActivityKind, hud: IslandSettings.LevelHUD, payload: LevelPayload) -> Activity {
        Activity(
            id: id, kind: kind, priority: .high,
            style: hud.style == .compact ? .compact(.wide) : .banner,
            lifetime: .transient(duration: hud.duration),
            updatePolicy: .restartTimer, requeueOnPreempt: false,
            payload: .level(payload)
        )
    }

    private func handleNowPlaying(_ snapshot: NowPlayingSnapshot?) {
        guard settings.music.isEnabled, let snapshot, let track = snapshot.track, snapshot.state != .stopped else {
            activities.end(.music)
            return
        }
        guard settings.music.showCompact else {
            activities.end(.music)
            return
        }
        let expiresAfter: TimeInterval?
        if snapshot.isPlaying {
            expiresAfter = nil
        } else if settings.music.pausedTimeout <= 0 {
            activities.end(.music)
            return
        } else {
            expiresAfter = settings.music.pausedTimeout
        }
        activities.upsert(Activity(
            id: .music, kind: .music, priority: .normal,
            title: track.title, subtitle: track.artist,
            style: .compact(.narrow), lifetime: .live(expiresAfter: expiresAfter),
            payload: .track(TrackPayload(title: track.title, artist: track.artist, album: track.album, source: snapshot.source))
        ))
    }

    private func handlePower(_ state: PowerState, _ change: PowerChange) {
        guard settings.power.isEnabled else { return dropped("power") }
        log?.append("power", "\(change) \(state.percent)%")
        switch change {
        case .pluggedIn, .unplugged, .fullyCharged:
            guard settings.power.showChargingChanges else { return }
            activities.upsert(Activity(
                id: .power, kind: .power, priority: .normal,
                style: .compact(.regular), lifetime: .transient(duration: 3),
                payload: .power(state)
            ))
        case .lowBattery:
            activities.upsert(Activity(
                id: .powerLow, kind: .power, priority: .high,
                title: "Low Battery", subtitle: "\(state.percent)% remaining",
                style: .banner, lifetime: .transient(duration: 6),
                requeueOnPreempt: true,
                payload: .power(state)
            ))
        }
    }

    private func dropped(_ what: String) {
        log?.append("router", "\(what) ignored (module disabled)")
    }
}

/// In-memory ring buffer of recent events for the diagnostics screen.
/// Never persisted; contains no track titles or notification text.
public final class DiagnosticsLog {
    public struct Entry: Identifiable, Equatable {
        public let id: Int
        public let date: Date
        public let category: String
        public let message: String
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []
    public var onChange: (() -> Void)?
    private var nextID = 0
    private let clock: () -> Date

    public init(capacity: Int = 200, clock: @escaping () -> Date = Date.init) {
        self.capacity = max(1, capacity)
        self.clock = clock
    }

    public func append(_ category: String, _ message: String) {
        nextID += 1
        entries.append(Entry(id: nextID, date: clock(), category: category, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        onChange?()
    }

    public func clear() {
        entries.removeAll()
        onChange?()
    }
}
