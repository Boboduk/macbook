import Foundation
import IslandCore

/// AppleScript sources for the scriptable players. Both Music and Spotify
/// document these terms in their scripting dictionaries (`sdef`).
///
/// Every script uses `tell application id …`, which compiles without
/// launching the player; callers check that the player is running before
/// executing a script, so the island never starts a player by itself.
enum MusicScripts {
    /// Returns `{state, name, artist, album, duration, position, id}`.
    /// Music reports the duration in seconds, Spotify in milliseconds.
    static func state(for source: MusicSourceKind) -> String {
        let identifierTerm = source == .appleMusic ? "persistent ID" : "id"
        return """
        tell application id "\(source.bundleIdentifier)"
            set playerState to player state as string
            if playerState is "stopped" then return {playerState, "", "", "", 0, 0, ""}
            set trackName to ""
            set trackArtist to ""
            set trackAlbum to ""
            set trackDuration to 0
            set trackID to ""
            set playerPosition to 0
            try
                set currentTrack to current track
                try
                    set trackName to name of currentTrack
                end try
                try
                    set trackArtist to artist of currentTrack
                end try
                try
                    set trackAlbum to album of currentTrack
                end try
                try
                    set trackDuration to duration of currentTrack
                end try
                try
                    set trackID to \(identifierTerm) of currentTrack
                end try
            end try
            try
                set playerPosition to player position
            end try
            return {playerState, trackName, trackArtist, trackAlbum, trackDuration, playerPosition, trackID}
        end tell
        """
    }

    /// Music: raw image data of the first artwork. Spotify: artwork URL.
    static func artwork(for source: MusicSourceKind) -> String {
        switch source {
        case .appleMusic:
            return """
            tell application id "com.apple.Music"
                try
                    if (count of artworks of current track) > 0 then
                        return raw data of artwork 1 of current track
                    end if
                end try
                return ""
            end tell
            """
        case .spotify:
            return """
            tell application id "com.spotify.client"
                try
                    return artwork url of current track
                end try
                return ""
            end tell
            """
        case .system:
            // System now-playing artwork is delivered by the MediaRemote
            // helper as image data; no AppleScript is involved.
            return ""
        }
    }

    static func playPause(for source: MusicSourceKind) -> String {
        "tell application id \"\(source.bundleIdentifier)\" to playpause"
    }

    static func nextTrack(for source: MusicSourceKind) -> String {
        "tell application id \"\(source.bundleIdentifier)\" to next track"
    }

    static func previousTrack(for source: MusicSourceKind) -> String {
        "tell application id \"\(source.bundleIdentifier)\" to previous track"
    }

    static func seek(to seconds: TimeInterval, for source: MusicSourceKind) -> String {
        let value = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, seconds))
        return "tell application id \"\(source.bundleIdentifier)\" to set player position to \(value)"
    }
}
