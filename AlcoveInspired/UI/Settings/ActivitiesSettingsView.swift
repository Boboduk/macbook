import IslandCore
import SwiftUI

struct ActivitiesSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var store = model.settings
        let settings = store.settings

        Form {
            // MARK: Music
            Section {
                Toggle("Music", isOn: $store.settings.music.isEnabled)
                if settings.music.isEnabled {
                    Picker("Preferred player", selection: $store.settings.music.preferredSource) {
                        Text("Automatic").tag(MusicSourcePreference.automatic)
                        Text("Music").tag(MusicSourcePreference.appleMusic)
                        Text("Spotify").tag(MusicSourcePreference.spotify)
                    }
                    Toggle("Show beside the notch while playing", isOn: $store.settings.music.showCompact)
                    Toggle("Show track changes", isOn: $store.settings.music.peekOnTrackChange)
                    Toggle("Playback indicator", isOn: $store.settings.music.showPlaybackIndicator)
                    SliderRow(title: "Keep paused player for", value: $store.settings.music.pausedTimeout, range: 0...300, step: 5) { value in
                        value == 0 ? String(localized: "Hide") : SettingsFormat.duration(value)
                    }
                    Toggle("Load Spotify artwork from the internet", isOn: $store.settings.music.loadRemoteArtwork)
                    ForEach(MusicSourceKind.allCases) { source in
                        AutomationRow(source: source)
                    }
                }
            } header: {
                Text("Music")
            } footer: {
                Text("Track details come from Music and Spotify notifications. Artwork, progress and controls need permission to control the player (Automation). Other players are not supported: macOS offers no public API for them.")
            }

            // MARK: Volume & brightness
            Section {
                Toggle("Volume HUD", isOn: $store.settings.volume.hud.isEnabled)
                if settings.volume.hud.isEnabled {
                    HUDStylePicker(selection: $store.settings.volume.hud.style)
                    SliderRow(title: "Display time", value: $store.settings.volume.hud.duration, range: 0.8...6, step: 0.1, format: SettingsFormat.seconds)
                    Toggle("Show output device changes", isOn: $store.settings.volume.showOutputDeviceChanges)
                    StatusRow(
                        title: "Output",
                        value: model.volume.deviceName.map { Text(verbatim: $0) } ?? Text("No output device"),
                        isOK: model.volume.isAvailable
                    )
                }
                Toggle("Brightness HUD", isOn: $store.settings.brightness.isEnabled)
                if settings.brightness.isEnabled {
                    HUDStylePicker(selection: $store.settings.brightness.style)
                    SliderRow(title: "Display time", value: $store.settings.brightness.duration, range: 0.8...6, step: 0.1, format: SettingsFormat.seconds)
                    StatusRow(
                        title: "Built-in display",
                        value: model.brightness.isAvailable ? Text("Available") : Text("Not available on this Mac or display"),
                        isOK: model.brightness.isAvailable
                    )
                }
            } header: {
                Text("Volume & Brightness")
            } footer: {
                Text("The volume HUD follows the system volume of the current output. The brightness HUD reacts to the brightness keys and needs Accessibility access; changes made in Control Center are not reported by macOS.")
            }

            // MARK: Media keys
            Section {
                Toggle("Replace the system volume and brightness HUD", isOn: $store.settings.mediaKeys.replaceSystemHUD)
                MediaKeysStatusRow()
            } header: {
                Text("Media Keys")
            } footer: {
                Text("When enabled, the volume and brightness keys are handled by AlcoveInspired so only the island HUD appears (⌥⇧ for fine steps). Requires Accessibility access.")
            }

            // MARK: Timer
            Section {
                Toggle("Timer and stopwatch", isOn: $store.settings.timer.isEnabled)
                if settings.timer.isEnabled {
                    Stepper(value: Binding(
                        get: { store.settings.timer.defaultDuration / 60 },
                        set: { store.settings.timer.defaultDuration = $0 * 60 }
                    ), in: 1...180, step: 1) {
                        LabeledContent("Default duration", value: SettingsFormat.duration(settings.timer.defaultDuration))
                    }
                    Toggle("Show beside the notch while running", isOn: $store.settings.timer.showCompact)
                    Toggle("Play sound when finished", isOn: $store.settings.timer.playSound)
                    Toggle("System notification when finished", isOn: $store.settings.timer.systemNotification)
                    if settings.timer.systemNotification {
                        NotificationPermissionRow()
                    }
                }
            } header: {
                Text("Timer")
            }

            // MARK: Notifications
            Section {
                Toggle("Island notifications", isOn: $store.settings.notifications.isEnabled)
                if settings.notifications.isEnabled {
                    SliderRow(title: "Display time", value: $store.settings.notifications.duration, range: 2...15, step: 0.5, format: SettingsFormat.seconds)
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Messages from AlcoveInspired itself (timer finished, permission problems, output device changes). Notifications of other apps are not available through public macOS APIs.")
            }

            // MARK: Battery
            Section {
                Toggle("Battery", isOn: $store.settings.power.isEnabled)
                if settings.power.isEnabled {
                    Toggle("Show charger connected / disconnected", isOn: $store.settings.power.showChargingChanges)
                    Stepper(value: $store.settings.power.lowBatteryThreshold, in: 5...50, step: 5) {
                        LabeledContent("Low battery warning at", value: "\(settings.power.lowBatteryThreshold)%")
                    }
                    StatusRow(
                        title: "Battery",
                        value: batteryText,
                        isOK: model.power.hasBattery
                    )
                }
            } header: {
                Text("Battery")
            }
        }
    }
}

extension ActivitiesSettingsView {
    private var batteryText: Text {
        let state = model.power.state
        guard state.hasBattery else { return Text("No battery") }
        return state.isPluggedIn
            ? Text("\(state.percent)%, on power adapter")
            : Text(verbatim: "\(state.percent)%")
    }
}

private struct HUDStylePicker: View {
    @Binding var selection: HUDStyle

    var body: some View {
        Picker("Style", selection: $selection) {
            Text("Beside the notch").tag(HUDStyle.compact)
            Text("Below the notch").tag(HUDStyle.banner)
        }
    }
}

struct StatusRow: View {
    let title: LocalizedStringKey
    let value: Text
    let isOK: Bool

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOK ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                value
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
        }
    }
}

/// Automation permission for one player, with the action that fixes it.
struct AutomationRow: View {
    let source: MusicSourceKind
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.permissions.automation[source] ?? .appNotRunning
        LabeledContent("Control \(source.displayName)") {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: status))
                    .frame(width: 7, height: 7)
                islandText(status.title)
                    .foregroundStyle(.secondary)
                switch status {
                case .notDetermined:
                    Button("Allow…") { model.permissions.requestAutomation(for: source) { _ in model.music.refreshAll() } }
                        .controlSize(.small)
                case .denied:
                    Button("Open Settings…") { model.permissions.open(.automation) }
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func color(for status: AutomationStatus) -> Color {
        switch status {
        case .granted: return .green
        case .denied: return .red
        default: return .orange
        }
    }
}

struct NotificationPermissionRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let status = model.permissions.notifications
        LabeledContent("Notification permission") {
            HStack(spacing: 8) {
                islandText(status.title)
                    .foregroundStyle(.secondary)
                switch status {
                case .notDetermined:
                    Button("Allow…") { model.permissions.requestNotifications() }
                        .controlSize(.small)
                case .denied:
                    Button("Open Settings…") { model.permissions.open(.notifications) }
                        .controlSize(.small)
                default:
                    EmptyView()
                }
            }
        }
    }
}

struct MediaKeysStatusRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let trusted = model.permissions.isAccessibilityTrusted
        LabeledContent("Accessibility access") {
            HStack(spacing: 8) {
                Circle()
                    .fill(trusted ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                statusText(trusted: trusted)
                    .foregroundStyle(.secondary)
                if !trusted {
                    Button("Grant…") { model.requestAccessibility() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func statusText(trusted: Bool) -> Text {
        guard trusted else { return Text("Not granted") }
        switch model.mediaKeyState {
        case .off: return Text("Granted (keys not used)")
        case .needsPermission: return Text("Granted, key monitor unavailable")
        case .observing: return Text("Granted, observing brightness keys")
        case .replacing: return Text("Granted, replacing system HUD")
        }
    }
}
