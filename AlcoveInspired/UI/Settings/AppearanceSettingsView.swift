import IslandCore
import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settings

        Form {
            Section {
                IslandPreview(appearance: store.settings.appearance)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }

            Section("Island") {
                Picker("Size", selection: $store.settings.appearance.size) {
                    Text("Compact").tag(IslandSizeOption.compact)
                    Text("Standard").tag(IslandSizeOption.standard)
                    Text("Large").tag(IslandSizeOption.large)
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Corner radius", value: $store.settings.appearance.cornerRadius, range: 12...36, step: 1, format: SettingsFormat.points)
                SliderRow(title: "Animation speed", value: $store.settings.appearance.animationSpeed, range: 0.5...1.6, step: 0.1, format: SettingsFormat.multiplier)
                SliderRow(title: "Secondary text", value: $store.settings.appearance.secondaryOpacity, range: 0.3...0.9, step: 0.05, format: SettingsFormat.percent)
                Toggle("Shadow under the expanded island", isOn: $store.settings.appearance.showShadow)
            }

            Section("Accent color") {
                AccentPicker(selection: $store.settings.appearance.accent)
            }

            Section("Settings window") {
                Picker("Appearance", selection: $store.settings.appearance.settingsTheme) {
                    Text("System").tag(ThemeOption.system)
                    Text("Light").tag(ThemeOption.light)
                    Text("Dark").tag(ThemeOption.dark)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

/// Static preview of the expanded island with the current appearance.
private struct IslandPreview: View {
    let appearance: IslandSettings.Appearance

    var body: some View {
        let accent = IslandTheme.accent(appearance)
        let scale = appearance.size.scale
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.55), Color(white: 0.75)], startPoint: .top, endPoint: .bottom))
            IslandShape(topRadius: 10, bottomRadius: CGFloat(appearance.cornerRadius) * 0.8)
                .fill(Color.black)
                .frame(width: 300 * scale, height: 104 * scale)
                .shadow(color: .black.opacity(appearance.showShadow ? 0.45 : 0), radius: 12, y: 6)
                .overlay(alignment: .bottom) {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(accent.opacity(0.85))
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Song Title")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("Artist — Album")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.white.opacity(appearance.secondaryOpacity))
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .frame(height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(accent).frame(width: 90, height: 4)
                                }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 14)
                }
        }
        .frame(height: 140)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appearance)
        .accessibilityHidden(true)
    }
}

private struct AccentPicker: View {
    @Binding var selection: AccentOption

    var body: some View {
        HStack(spacing: 10) {
            ForEach(AccentOption.allCases) { option in
                Button {
                    selection = option
                } label: {
                    swatch(for: option)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.primary.opacity(selection == option ? 0.9 : 0), lineWidth: 2)
                                .padding(-3)
                        )
                }
                .buttonStyle(.plain)
                .help(title(for: option))
                .accessibilityLabel(Text(title(for: option)))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func swatch(for option: AccentOption) -> some View {
        switch option {
        case .system:
            Circle().fill(Color.accentColor)
        case .artwork:
            Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center))
        default:
            Circle().fill(IslandTheme.color(for: option))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
        }
    }

    private func title(for option: AccentOption) -> String {
        switch option {
        case .system: return "System accent"
        case .white: return "White"
        case .artwork: return "From album artwork"
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .orange: return "Orange"
        case .green: return "Green"
        case .teal: return "Teal"
        }
    }
}
