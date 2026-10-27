import IslandCore
import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        @Bindable var store = model.settings
        let general = store.settings.general

        Form {
            Section {
                Toggle("Show island", isOn: $store.settings.general.isEnabled)
                LaunchAtLoginRow()
                Toggle("Show menu bar icon", isOn: $store.settings.general.showMenuBarIcon)
            } footer: {
                if !general.showMenuBarIcon {
                    Text("Right-click the island to open Settings. Opening the app again from Finder also shows this window.")
                }
            }

            Section("Display") {
                Picker("Show on", selection: $store.settings.general.displayTarget) {
                    Text("Display with notch (automatic)").tag(DisplayTarget.automatic)
                    Text("Main display").tag(DisplayTarget.mainDisplay)
                }
                Toggle("Hide in full-screen apps", isOn: $store.settings.general.hideInFullscreen)
                Toggle("Show idle island on displays without a notch", isOn: $store.settings.general.fallbackIdleVisible)
            }

            Section("Interaction") {
                Picker("When the pointer hovers", selection: $store.settings.general.hoverBehavior) {
                    Text("Do nothing").tag(HoverBehavior.none)
                    Text("Highlight").tag(HoverBehavior.highlight)
                    Text("Expand").tag(HoverBehavior.expand)
                }
                if general.hoverBehavior == .expand {
                    SliderRow(title: "Hover delay", value: $store.settings.general.hoverDelay, range: 0...1.5, step: 0.05, format: SettingsFormat.seconds)
                }
                Toggle("Collapse when the pointer leaves", isOn: $store.settings.general.collapseOnExit)
                if general.collapseOnExit || general.hoverBehavior == .expand {
                    SliderRow(title: "Collapse delay", value: $store.settings.general.collapseDelay, range: 0...2, step: 0.05, format: SettingsFormat.seconds)
                }
                Toggle("Keep expanded (pin)", isOn: $store.settings.general.isPinned)
                Toggle("Swipe gestures", isOn: $store.settings.general.swipeGestures)
                if general.swipeGestures {
                    Toggle("Haptic feedback on swipe", isOn: $store.settings.general.hapticFeedback)
                }
            } footer: {
                Text("Click the island to expand or collapse it. Swipe down on the island to expand, up to collapse, left or right to change tracks.")
            }

            Section("Live activities") {
                Toggle("Show live activities beside the notch", isOn: $store.settings.general.showLiveActivities)
            } footer: {
                Text("Music and timers appear in the compact island while they run. HUDs and notifications temporarily take their place.")
            }

            Section {
                Button("Restore Default Settings…", role: .destructive) {
                    confirmReset = true
                }
            }
        }
        .confirmationDialog("Restore all settings to their defaults?", isPresented: $confirmReset) {
            Button("Restore Defaults", role: .destructive) {
                model.settings.resetToDefaults()
            }
        } message: {
            Text("This cannot be undone. Permissions granted in System Settings are not affected.")
        }
    }
}

/// Launch at login is stored by the system (Login Items), not in our settings.
struct LaunchAtLoginRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let service = model.launchAtLogin
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(
                get: { service.isEnabled },
                set: { service.setEnabled($0) }
            ))
            if let message = service.statusMessage {
                HStack(spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if service.needsApproval {
                        Button("Open Login Items…") { service.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .onAppear { service.refresh() }
    }
}
