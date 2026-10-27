import Foundation

/// Commands understood by the NowPlayingHelper (one per line on its stdin).
public enum MediaRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case seek(TimeInterval)
    case refresh

    public var line: String {
        switch self {
        case .play: return "play"
        case .pause: return "pause"
        case .togglePlayPause: return "toggle"
        case .nextTrack: return "next"
        case .previousTrack: return "previous"
        case let .seek(seconds): return String(format: "seek %.3f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        case .refresh: return "refresh"
        }
    }
}

/// One JSON line printed by the NowPlayingHelper.
public enum MediaRemoteMessage: Equatable, Sendable {
    /// The helper loaded MediaRemote and is listening.
    case ready
    /// The helper cannot work on this system.
    case error(String)
    /// Current system now-playing state (`snapshot == nil`: nothing playing).
    case nowPlaying(MediaRemoteUpdate)
}

public struct MediaRemoteUpdate: Equatable, Sendable {
    public var snapshot: NowPlayingSnapshot?
    /// New artwork bytes; `nil` means "unchanged" while `hasArtwork` is true.
    public var artwork: Data?
    public var hasArtwork: Bool

    public init(snapshot: NowPlayingSnapshot?, artwork: Data?, hasArtwork: Bool) {
        self.snapshot = snapshot
        self.artwork = artwork
        self.hasArtwork = hasArtwork
    }
}

/// Parses the helper's line protocol. Kept in the core so the format is
/// unit-tested on every platform.
///
/// ```json
/// {"type":"nowPlaying","playing":true,"bundleIdentifier":"com.google.Chrome",
///  "appName":"Google Chrome","title":"…","artist":"…","album":"…",
///  "duration":215.2,"elapsed":12.5,"timestamp":1730000000.5,"rate":1,
///  "id":"…","hasArtwork":true,"artwork":"<base64, only when changed>"}
/// ```
public enum MediaRemoteParser {
    public static func parse(line: Data, now: Date = Date()) -> MediaRemoteMessage? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "ready":
            return .ready
        case "error":
            return .error(object["message"] as? String ?? "Unknown error")
        case "nowPlaying":
            return .nowPlaying(parseNowPlaying(object, now: now))
        default:
            return nil
        }
    }

    static func parseNowPlaying(_ object: [String: Any], now: Date) -> MediaRemoteUpdate {
        let title = NowPlayingParser.string(object["title"]) ?? ""
        let artist = NowPlayingParser.string(object["artist"]) ?? ""
        let album = NowPlayingParser.string(object["album"]) ?? ""
        let hasArtwork = (object["hasArtwork"] as? Bool) ?? false
        let artwork = (object["artwork"] as? String).flatMap { Data(base64Encoded: $0) }

        guard (object["empty"] as? Bool) != true, !(title.isEmpty && artist.isEmpty && album.isEmpty) else {
            return MediaRemoteUpdate(snapshot: nil, artwork: nil, hasArtwork: false)
        }

        let duration = NowPlayingParser.number(object["duration"]).flatMap { $0 > 0 ? $0 : nil }
        let rate = NowPlayingParser.number(object["rate"]) ?? 0
        let playing = (object["playing"] as? Bool) ?? (rate > 0)
        let identifier = NowPlayingParser.string(object["id"]).flatMap { $0.isEmpty ? nil : $0 }
            ?? NowPlayingParser.syntheticID(title: title, artist: artist, album: album)

        var position: PlaybackPosition?
        if let elapsed = NowPlayingParser.number(object["elapsed"]) {
            let timestamp = NowPlayingParser.number(object["timestamp"]).map { Date(timeIntervalSince1970: $0) } ?? now
            // MediaRemote anchors the elapsed time at `timestamp`; a stale
            // anchor in the future (clock skew) is clamped to now.
            position = PlaybackPosition(
                elapsed: elapsed,
                timestamp: min(timestamp, now),
                rate: playing ? (rate > 0 ? rate : 1) : 0
            )
        }

        let snapshot = NowPlayingSnapshot(
            source: .system,
            track: TrackInfo(id: identifier, title: title, artist: artist, album: album, duration: duration),
            state: playing ? .playing : .paused,
            position: position,
            playerBundleIdentifier: NowPlayingParser.string(object["bundleIdentifier"]),
            playerName: NowPlayingParser.string(object["appName"])
        )
        return MediaRemoteUpdate(snapshot: snapshot, artwork: artwork, hasArtwork: hasArtwork || artwork != nil)
    }
}
