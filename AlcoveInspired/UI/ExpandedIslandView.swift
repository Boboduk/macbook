import IslandCore
import SwiftUI

/// The full island: a header row beside the notch (pages on the left,
/// pin/settings on the right) and the selected page below. A HUD or
/// notification that arrives meanwhile slides in as a capsule at the bottom.
struct ExpandedIslandView: View {
    let context: ExpandedContext
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.coordinator
        let notch = coordinator.metrics.notchSize
        let frame = IslandLayout.frame(for: .expanded, metrics: coordinator.metrics, config: coordinator.layoutConfig)

        VStack(spacing: 0) {
            header(notchWidth: notch.width)
                .frame(height: notch.height)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, 6)
        }
        .padding(.horizontal, 16 + frame.topRadius)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            if let transient = visibleTransient {
                TransientOverlayView(activity: transient)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(coordinator.springAnimation(response: 0.32, damping: 0.85), value: visibleTransient?.id)
    }

    /// The music peek is redundant while the music page is open.
    private var visibleTransient: Activity? {
        guard let transient = context.transient else { return nil }
        if transient.id == .musicPeek && context.tab == .music { return nil }
        return transient
    }

    private func header(notchWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(context.availableTabs) { tab in
                    TabButton(tab: tab, isSelected: tab == context.tab) {
                        model.coordinator.selectTab(tab)
                    }
                }
            }
            Spacer(minLength: notchWidth + 16)
            HStack(spacing: 6) {
                HeaderButton(
                    symbol: context.isPinned ? "pin.fill" : "pin",
                    label: context.isPinned ? "Unpin" : "Pin",
                    isActive: context.isPinned
                ) {
                    model.togglePinned()
                }
                HeaderButton(symbol: "gearshape", label: "Settings", isActive: false) {
                    model.showSettings()
                }
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch context.tab {
        case .music:
            MusicPanelView()
                .transition(.opacity)
        case .timer:
            TimerPanelView()
                .transition(.opacity)
        case nil:
            EmptyStateView(
                symbol: "square.dashed",
                title: "Nothing to show",
                message: "Enable Music or Timer in Settings › Activities.",
                actionTitle: "Open Settings"
            ) {
                model.showSettings()
            }
        }
    }
}

private struct TabButton: View {
    let tab: IslandTab
    let isSelected: Bool
    let action: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: action) {
            Image(systemName: tab == .music ? "music.note" : "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.8))
                .frame(width: 30, height: 22)
                .background(
                    Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(tab == .music ? "Music" : "Timer")
        .accessibilityLabel(Text(tab == .music ? "Music" : "Timer"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct HeaderButton: View {
    let symbol: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.7))
                .frame(width: 24, height: 22)
                .background(Circle().fill(Color.white.opacity(isActive ? 0.2 : 0.08)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// HUD or message shown on top of the expanded island.
struct TransientOverlayView: View {
    let activity: Activity
    @Environment(AppModel.self) private var model

    var body: some View {
        let appearance = model.coordinator.appearance
        HStack(spacing: 10) {
            switch activity.payload {
            case let .level(level):
                Image(systemName: activity.kind == .brightness
                    ? IslandTheme.brightnessSymbol(level: level.value)
                    : IslandTheme.volumeSymbol(level: level.value, muted: level.isMuted))
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 18)
                LevelBar(value: level.isMuted ? 0 : level.value, tint: IslandTheme.accent(appearance), height: 5)
                    .frame(width: 140, height: 12)
            case let .message(message):
                Image(systemName: message.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(message.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            case let .track(track):
                Image(systemName: "music.note")
                    .font(.system(size: 12, weight: .semibold))
                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            case let .power(state):
                Image(systemName: IslandTheme.batterySymbol(state))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(state.percent)%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            case .none:
                Text(activity.title)
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Color(white: 0.16)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .onTapGesture { model.coordinator.dismissTransient() }
    }
}

/// Fallback content for missing data or permissions (state F): never an empty
/// or broken view, always an explanation and, when possible, an action.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    @Environment(AppModel.self) private var model

    var body: some View {
        let appearance = model.coordinator.appearance
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(IslandTheme.secondaryText(appearance))
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IslandTheme.secondaryText(appearance))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(IslandCapsuleButtonStyle())
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }
}

/// Small white-on-dark capsule button used inside the island.
struct IslandCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.7 : 0.92)))
    }
}
