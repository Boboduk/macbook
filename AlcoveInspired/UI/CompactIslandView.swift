import IslandCore
import SwiftUI

/// Live activity or HUD beside the notch: content lives in the two "wings",
/// the middle stays empty behind the camera housing.
struct CompactIslandView: View {
    let activity: Activity
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.coordinator
        let wing: WingSize = {
            if case let .compact(size) = activity.style { return size }
            return .regular
        }()
        let frame = IslandLayout.frame(for: .compact(wing, hovered: false), metrics: coordinator.metrics, config: coordinator.layoutConfig)
        let notch = coordinator.metrics.notchSize
        let wingWidth = max(0, (frame.size.width - notch.width) / 2 - frame.topRadius)

        HStack(spacing: 0) {
            leading
                .frame(width: wingWidth, height: notch.height)
            Color.clear
                .frame(width: notch.width, height: notch.height)
            trailing
                .frame(width: wingWidth, height: notch.height)
        }
        .padding(.horizontal, frame.topRadius)
        .frame(height: notch.height)
    }

    @ViewBuilder
    private var leading: some View {
        switch activity.kind {
        case .music:
            MusicCompactLeading()
        case .timer:
            TimerCompactLeading()
        default:
            switch activity.payload {
            case let .level(level):
                LevelCompactLeading(kind: activity.kind, level: level)
            case let .power(state):
                PowerCompactLeading(state: state)
            case let .message(message):
                CompactSymbol(name: message.symbol)
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch activity.kind {
        case .music:
            MusicCompactTrailing()
        case .timer:
            TimerCompactTrailing()
        default:
            switch activity.payload {
            case let .level(level):
                LevelCompactTrailing(kind: activity.kind, level: level)
            case let .power(state):
                PowerCompactTrailing(state: state)
            default:
                EmptyView()
            }
        }
    }
}

/// SF Symbol sized for the compact wings.
struct CompactSymbol: View {
    let name: String
    var color: Color = .white
    var variableValue: Double?

    var body: some View {
        Image(systemName: name, variableValue: variableValue)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Level HUD (volume, brightness)

struct LevelCompactLeading: View {
    let kind: ActivityKind
    let level: LevelPayload

    var body: some View {
        if kind == .brightness {
            CompactSymbol(name: IslandTheme.brightnessSymbol(level: level.value))
        } else {
            CompactSymbol(name: IslandTheme.volumeSymbol(level: level.value, muted: level.isMuted))
        }
    }
}

struct LevelCompactTrailing: View {
    let kind: ActivityKind
    let level: LevelPayload
    @Environment(AppModel.self) private var model

    var body: some View {
        let appearance = model.coordinator.appearance
        LevelBar(
            value: level.isMuted ? 0 : level.value,
            tint: IslandTheme.accent(appearance),
            height: 5,
            onChange: model.levelSetter(for: kind),
            onEditingChanged: { editing in
                editing ? model.coordinator.beginInteraction() : model.coordinator.endInteraction()
            }
        )
        .padding(.leading, 4)
        .padding(.trailing, 12)
    }
}

// MARK: - Power

struct PowerCompactLeading: View {
    let state: PowerState
    @Environment(AppModel.self) private var model

    var body: some View {
        CompactSymbol(
            name: IslandTheme.batterySymbol(state),
            color: IslandTheme.batteryColor(state, lowThreshold: model.settings.settings.power.lowBatteryThreshold)
        )
    }
}

struct PowerCompactTrailing: View {
    let state: PowerState

    var body: some View {
        Text("\(state.percent)%")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText(value: Double(state.percent)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
