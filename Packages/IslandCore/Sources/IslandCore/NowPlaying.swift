import Foundation

/// Players with a documented scripting interface and public change notifications.
public enum MusicSourceKind: String, Codable, CaseIterable, Identifiable {
    case appleMusic
    case spotify

    public var id: String { rawValue }

    public var bundleIdentifier: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    public var displayName: String {
        switch self {
        case .appleMusic: return "Music"
        case .spotify: return "Spotify"
        }
    }

    /// Distributed notification posted by the player on every state change.
    public var changeNotificationName: String {
        switch self {
        case .appleMusic: return "com.apple.Music.playerInfo"
        case .spotify: return "com.spotify.client.PlaybackStateChanged"
        }
    }
}

public enum PlaybackState: String, Codable, Equatable {
    case playing
    case paused
    case stopped

    public init(playerStateString: String) {
        switch playerStateString.lowercased() {
        case "playing": self = .playing
        case "paused": self = .paused
        default: self = .stopped
        }
    }
}

public struct TrackInfo: Equatable {
    /// Stable identifier (persistent id / Spotify URI), or a synthetic one.
    public var id: String
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; `nil` for streams without a known length.
    public var duration: TimeInterval?

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
    }
}

/// Playback position anchored at a point in time. The UI derives the current
/// position from it instead of asking the player every second.
public struct PlaybackPosition: Equatable {
    public var elapsed: TimeInterval
    public var timestamp: Date
    /// 1 while playing, 0 while paused.
    public var rate: Double

    public init(elapsed: TimeInterval, timestamp: Date, rate: Double) {
        self.elapsed = max(0, elapsed)
        self.timestamp = timestamp
        self.rate = rate
    }

    public func elapsed(at date: Date, duration: TimeInterval?) -> TimeInterval {
        let value = elapsed + max(0, date.timeIntervalSince(timestamp)) * rate
        if let duration, duration > 0 { return min(max(0, value), duration) }
        return max(0, value)
    }
}

public struct NowPlayingSnapshot: Equatable {
    public var source: MusicSourceKind
    public var track: TrackInfo?
    public var state: PlaybackState
    /// `nil` when the notification did not include a position.
    public var position: PlaybackPosition?

    public init(source: MusicSourceKind, track: TrackInfo?, state: PlaybackState, position: PlaybackPosition?) {
        self.source = source
        self.track = track
        self.state = state
        self.position = position
    }

    public var isPlaying: Bool { state == .playing }
}

/// Converts the player's notification `userInfo` and AppleScript replies into
/// `NowPlayingSnapshot`. Kept free of AppKit so it can be unit tested.
public enum NowPlayingParser {
    /// Parses a `com.apple.Music.playerInfo` / `com.spotify.client.PlaybackStateChanged` payload.
    public static func parseNotification(_ userInfo: [AnyHashable: Any], source: MusicSourceKind, at now: Date) -> NowPlayingSnapshot {
        let state = PlaybackState(playerStateString: string(userInfo["Player State"]) ?? "")
        let title = string(userInfo["Name"]) ?? ""
        let artist = string(userInfo["Artist"]) ?? ""
        let album = string(userInfo["Album"]) ?? ""

        let duration: TimeInterval?
        let identifier: String?
        var position: PlaybackPosition?

        switch source {
        case .appleMusic:
            duration = number(userInfo["Total Time"]).map { $0 / 1000 }
            identifier = (userInfo["PersistentID"]).flatMap(identifierString)
        case .spotify:
            duration = number(userInfo["Duration"]).map { $0 / 1000 }
            identifier = string(userInfo["Track ID"])
            if let elapsed = number(userInfo["Playback Position"]) {
                position = PlaybackPosition(elapsed: elapsed, timestamp: now, rate: state == .playing ? 1 : 0)
            }
        }

        let track: TrackInfo?
        if state == .stopped || (title.isEmpty && artist.isEmpty && album.isEmpty) {
            track = nil
        } else {
            track = TrackInfo(
                id: identifier ?? syntheticID(title: title, artist: artist, album: album),
                title: title,
                artist: artist,
                album: album,
                duration: (duration ?? 0) > 0 ? duration : nil
            )
        }
        return NowPlayingSnapshot(source: source, track: track, state: track == nil ? .stopped : state, position: position)
    }

    /// Parses the list returned by the state AppleScript:
    /// `{state, name, artist, album, duration, position, id}`.
    /// Music reports `duration` in seconds, Spotify in milliseconds.
    public static func parseScriptFields(_ fields: [Any?], source: MusicSourceKind, at now: Date) -> NowPlayingSnapshot? {
        guard fields.count >= 7, let stateString = string(fields[0]) else { return nil }
        let state = PlaybackState(playerStateString: stateString)
        let title = string(fields[1]) ?? ""
        let artist = string(fields[2]) ?? ""
        let album = string(fields[3]) ?? ""
        var duration = number(fields[4])
        if source == .spotify { duration = duration.map { $0 / 1000 } }
        let elapsed = number(fields[5]) ?? 0
        let rawIdentifier = string(fields[6]).flatMap { $0.isEmpty ? nil : $0 }
        let identifier = source == .appleMusic ? rawIdentifier?.uppercased() : rawIdentifier

        guard state != .stopped, !(title.isEmpty && artist.isEmpty && album.isEmpty) else {
            return NowPlayingSnapshot(source: source, track: nil, state: .stopped, position: nil)
        }
        let track = TrackInfo(
            id: identifier ?? syntheticID(title: title, artist: artist, album: album),
            title: title,
            artist: artist,
            album: album,
            duration: (duration ?? 0) > 0 ? duration : nil
        )
        let position = PlaybackPosition(elapsed: elapsed, timestamp: now, rate: state == .playing ? 1 : 0)
        return NowPlayingSnapshot(source: source, track: track, state: state, position: position)
    }

    public static func syntheticID(title: String, artist: String, album: String) -> String {
        "\(title)|\(artist)|\(album)"
    }

    // MARK: - Value coercion

    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let int64 as Int64: return Double(int64)
        case let float as Float: return Double(float)
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    /// Music reports the persistent ID as a signed 64-bit number in
    /// notifications and as 16 hex digits in AppleScript; normalize both to hex
    /// so the same track is never mistaken for a new one.
    private static func identifierString(_ value: Any) -> String? {
        switch value {
        case let string as String: return string.isEmpty ? nil : string.uppercased()
        case let int as Int: return hexIdentifier(Int64(int))
        case let int64 as Int64: return hexIdentifier(int64)
        case let number as NSNumber: return hexIdentifier(number.int64Value)
        default: return nil
        }
    }

    public static func hexIdentifier(_ value: Int64) -> String {
        String(format: "%016llX", UInt64(bitPattern: value))
    }
}
