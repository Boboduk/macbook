import IslandCore
import SwiftUI

// MARK: - Compact

struct MusicCompactLeading: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let height = model.coordinator.metrics.notchSize.height
        ArtworkView(size: max(14, height - 12), cornerRadius: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MusicCompactTrailing: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.settings.settings.music.showPlaybackIndicator {
                PlaybackIndicatorView(barCount: 4)
                    .frame(width: 16, height: 14)
            } else {
                Image(systemName: model.music.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Expanded page

struct MusicPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let music = model.music
        if !music.isEnabled {
            EmptyStateView(
                symbol: "music.note",
                title: "Music is turned off",
                message: "Turn it on in Settings › Activities.",
                actionTitle: "Open Settings"
            ) { model.showSettings() }
        } else if let snapshot = music.snapshot, let track = snapshot.track {
            NowPlayingView(snapshot: snapshot, track: track)
        } else {
            EmptyStateView(
                symbol: "music.note",
                title: "Nothing playing",
                message: "Play something in Music or Spotify to control it here.",
                actionTitle: "Open Music"
            ) { music.openPlayer() }
        }
    }
}

private struct NowPlayingView: View {
    let snapshot: NowPlayingSnapshot
    let track: TrackInfo
    @Environment(AppModel.self) private var model

    var body: some View {
        let music = model.music
        let appearance = model.coordinator.appearance
        let accent = IslandTheme.accent(appearance, artworkColor: music.artworkColor)

        HStack(alignment: .center, spacing: 14) {
            ArtworkView(size: 78, cornerRadius: 13)
                .onTapGesture { music.openPlayer() }
                .help("Open \(snapshot.source.displayName)")

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title.isEmpty ? "Unknown title" : track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(IslandTheme.secondaryText(appearance))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    SourceBadge(source: snapshot.source)
                }
                .id(track.id)
                .transition(.opacity)

                ProgressRow(snapshot: snapshot, accent: accent)

                HStack(spacing: 4) {
                    Spacer(minLength: 0)
                    IslandIconButton(symbol: "backward.fill", size: 13, label: "Previous track") { music.previous() }
                    IslandIconButton(
                        symbol: snapshot.isPlaying ? "pause.fill" : "play.fill",
                        size: 15,
                        isProminent: true,
                        label: snapshot.isPlaying ? "Pause" : "Play"
                    ) { music.playPause() }
                    IslandIconButton(symbol: "forward.fill", size: 13, label: "Next track") { music.next() }
                    Spacer(minLength: 0)
                }
                .disabled(music.automationStatus == .denied)
                .opacity(music.automationStatus == .denied ? 0.4 : 1)
            }
        }
        .overlay(alignment: .bottom) {
            PermissionHint()
        }
        .animation(.smooth(duration: 0.3), value: track.id)
    }

    private var subtitle: String {
        [track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

private struct SourceBadge: View {
    let source: MusicSourceKind

    var body: some View {
        Text(source.displayName)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.65))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

/// Elapsed / remaining time and a scrubbable bar. Re-renders once per second
/// only while playing; frozen while paused.
private struct ProgressRow: View {
    let snapshot: NowPlayingSnapshot
    let accent: Color
    @Environment(AppModel.self) private var model

    var body: some View {
        if snapshot.isPlaying, let position = snapshot.position {
            // Whole seconds of the elapsed time fall on (timestamp - elapsed) + k.
            TimelineView(AlignedSecondsSchedule(anchor: position.timestamp.addingTimeInterval(-position.elapsed))) { context in
                row(at: context.date)
            }
        } else {
            row(at: Date())
        }
    }

    private func row(at date: Date) -> some View {
        let music = model.music
        let appearance = model.coordinator.appearance
        let duration = snapshot.track?.duration
        let elapsed = music.elapsed(at: date)
        let progress = duration.map { $0 > 0 ? elapsed / $0 : 0 } ?? 0

        return HStack(spacing: 8) {
            Text(TimeFormatting.clock(elapsed))
                .frame(width: 38, alignment: .leading)
            ScrubBar(
                progress: progress,
                tint: accent,
                isEnabled: duration != nil && music.automationStatus == .granted,
                onCommit: { music.seek(toFraction: $0) },
                onEditingChanged: { editing in
                    editing ? model.coordinator.beginInteraction() : model.coordinator.endInteraction()
                }
            )
            .frame(height: 12)
            Text(duration.map { "-" + TimeFormatting.clock(max(0, $0 - elapsed), roundingUp: true) } ?? "Live")
                .frame(width: 42, alignment: .trailing)
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(IslandTheme.secondaryText(appearance))
    }
}

/// Explains why artwork / controls are missing and offers the fix.
private struct PermissionHint: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let music = model.music
        switch music.automationStatus {
        case .notDetermined?:
            hint(text: "Allow access to show artwork and use controls", button: "Allow") {
                music.requestAccess()
            }
        case .denied?:
            hint(text: "Control of \(music.source?.displayName ?? "the player") is not allowed", button: "Open Settings") {
                music.openAutomationSettings()
            }
        default:
            EmptyView()
        }
    }

    private func hint(text: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            Button(button, action: action)
                .buttonStyle(IslandCapsuleButtonStyle())
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color(white: 0.14)))
        .offset(y: 8)
    }
}
