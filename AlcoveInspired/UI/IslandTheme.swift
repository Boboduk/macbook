import IslandCore
import SwiftUI

/// Visual constants and helpers shared by all island views.
enum IslandTheme {
    static let primaryText = Color.white
    static let trackFill = Color.white.opacity(0.16)

    static func secondaryText(_ appearance: IslandSettings.Appearance) -> Color {
        Color.white.opacity(appearance.secondaryOpacity)
    }

    /// Accent used for progress bars, indicators and selected controls.
    static func accent(_ appearance: IslandSettings.Appearance, artworkColor: Color? = nil) -> Color {
        color(for: appearance.accent, artworkColor: artworkColor)
    }

    static func color(for option: AccentOption, artworkColor: Color? = nil) -> Color {
        switch option {
        case .system: return Color.accentColor
        case .white: return .white
        case .artwork: return artworkColor ?? .white
        case .blue: return Color(red: 0.25, green: 0.55, blue: 1.0)
        case .purple: return Color(red: 0.65, green: 0.45, blue: 1.0)
        case .pink: return Color(red: 1.0, green: 0.4, blue: 0.62)
        case .orange: return Color(red: 1.0, green: 0.6, blue: 0.25)
        case .green: return Color(red: 0.3, green: 0.85, blue: 0.5)
        case .teal: return Color(red: 0.25, green: 0.8, blue: 0.85)
        }
    }

    static func volumeSymbol(level: Double, muted: Bool) -> String {
        if muted || level <= 0.001 { return "speaker.slash.fill" }
        if level < 0.34 { return "speaker.wave.1.fill" }
        if level < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    static func brightnessSymbol(level: Double) -> String {
        level < 0.5 ? "sun.min.fill" : "sun.max.fill"
    }

    static func batterySymbol(_ state: PowerState) -> String {
        if state.isCharging || (state.isPluggedIn && state.percent >= 100) { return "battery.100percent.bolt" }
        switch state.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    static func batteryColor(_ state: PowerState, lowThreshold: Int) -> Color {
        if state.isCharging || state.isPluggedIn { return Color(red: 0.3, green: 0.85, blue: 0.45) }
        if state.percent <= lowThreshold { return Color(red: 1.0, green: 0.3, blue: 0.3) }
        return .white
    }
}

/// Blur + fade + slight scale used when the island content changes.
private struct IslandContentModifier: ViewModifier {
    var blur: CGFloat
    var opacity: Double
    var scale: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: blur)
            .opacity(opacity)
            .scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    /// New content sharpens into place slightly after the shape starts
    /// growing; old content fades out quickly so it never fights the shape.
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: IslandContentModifier(blur: 10, opacity: 0, scale: 0.94),
                identity: IslandContentModifier(blur: 0, opacity: 1, scale: 1)
            ),
            removal: .modifier(
                active: IslandContentModifier(blur: 6, opacity: 0, scale: 0.98),
                identity: IslandContentModifier(blur: 0, opacity: 1, scale: 1)
            )
        )
    }
}
