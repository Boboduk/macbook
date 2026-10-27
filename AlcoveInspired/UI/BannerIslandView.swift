import IslandCore
import SwiftUI

/// The island dropped below the notch to show a message: notification,
/// track change, timer completion, low battery, output device, or a HUD in
/// the "banner" style.
struct BannerIslandView: View {
    let activity: Activity
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.coordinator
        let notch = coordinator.metrics.notchSize
        let appearance = coordinator.appearance

        VStack(alignment: .leading, spacing: 0) {
            // Row beside the notch: keep it clear of the camera housing.
            Color.clear.frame(height: notch.height)
            HStack(alignment: .center, spacing: 12) {
                leadingVisual
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    content(appearance: appearance)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailingAccessory(appearance: appearance)
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)
        }
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var leadingVisual: some View {
        switch activity.payload {
        case .track:
            ArtworkView(size: 38, cornerRadius: 8)
        case let .message(message):
            if let bundleID = message.appBundleIdentifier,
               let icon = AppDirectory.shared.icon(for: bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
            } else {
                BannerSymbol(name: message.symbol)
            }
        case let .level(level):
            BannerSymbol(name: activity.kind == .brightness
                ? IslandTheme.brightnessSymbol(level: level.value)
                : IslandTheme.volumeSymbol(level: level.value, muted: level.isMuted))
        case let .power(state):
            BannerSymbol(
                name: IslandTheme.batterySymbol(state),
                color: IslandTheme.batteryColor(state, lowThreshold: model.settings.settings.power.lowBatteryThreshold)
            )
        case .none:
            BannerSymbol(name: "bell.fill")
        }
    }

    @ViewBuilder
    private func content(appearance: IslandSettings.Appearance) -> some View {
        switch activity.payload {
        case let .track(track):
            BannerTitle(text: Text(verbatim: track.title.isEmpty ? track.source.displayName : track.title))
            BannerSubtitle(text: Text(verbatim: track.artist.isEmpty ? track.album : track.artist), appearance: appearance)
        case let .message(message):
            BannerTitle(text: islandText(message.title))
            if !message.body.isEmpty {
                BannerSubtitle(text: islandText(message.body), appearance: appearance)
            }
        case let .level(level):
            BannerTitle(text: levelTitle(level))
            LevelBar(
                value: level.isMuted ? 0 : level.value,
                tint: IslandTheme.accent(appearance),
                height: 6,
                onChange: model.levelSetter(for: activity.kind),
                onEditingChanged: { editing in
                    editing ? model.coordinator.beginInteraction() : model.coordinator.endInteraction()
                }
            )
            .frame(height: 16)
        case let .power(state):
            if activity.id == .powerLow {
                BannerTitle(text: Text("Low Battery"))
                BannerSubtitle(text: Text("\(state.percent)% remaining"), appearance: appearance)
            } else {
                BannerTitle(text: state.isPluggedIn ? Text("Charging") : Text("On Battery"))
                BannerSubtitle(text: Text(verbatim: "\(state.percent)%"), appearance: appearance)
            }
        case .none:
            BannerTitle(text: islandText(activity.title))
            BannerSubtitle(text: islandText(activity.subtitle), appearance: appearance)
        }
    }

    private func levelTitle(_ level: LevelPayload) -> Text {
        if activity.kind == .brightness { return Text("Brightness") }
        if let detail = level.detail { return Text(verbatim: detail) }
        return Text("Volume")
    }

    @ViewBuilder
    private func trailingAccessory(appearance: IslandSettings.Appearance) -> some View {
        switch activity.payload {
        case let .level(level):
            Group {
                if level.isMuted {
                    Text("Muted")
                } else {
                    Text(verbatim: "\(Int((level.value * 100).rounded()))%")
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(IslandTheme.secondaryText(appearance))
                .contentTransition(.numericText(value: level.value))
        case .track:
            PlaybackIndicatorView(barCount: 4)
                .frame(width: 20, height: 16)
        default:
            EmptyView()
        }
    }
}

struct BannerSymbol: View {
    let name: String
    var color: Color = .white

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.1))
            Image(systemName: name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

struct BannerTitle: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(IslandTheme.primaryText)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

struct BannerSubtitle: View {
    let text: Text
    let appearance: IslandSettings.Appearance

    var body: some View {
        text
            .font(.system(size: 12))
            .foregroundStyle(IslandTheme.secondaryText(appearance))
            .lineLimit(2)
            .truncationMode(.tail)
    }
}
