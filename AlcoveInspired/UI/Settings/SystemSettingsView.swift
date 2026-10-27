import AppKit
import IslandCore
import SwiftUI

struct SystemSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Mac", value: AppInfo.hardwareModel)
                LabeledContent("Bundle identifier", value: Bundle.main.bundleIdentifier ?? "—")
            }

            Section("Permissions") {
                StatusRow(
                    title: "Accessibility (media keys)",
                    value: model.permissions.isAccessibilityTrusted ? "Granted" : "Not granted",
                    isOK: model.permissions.isAccessibilityTrusted
                )
                ForEach(MusicSourceKind.allCases) { source in
                    AutomationRow(source: source)
                }
                NotificationPermissionRow()
                StatusRow(
                    title: "Launch at login",
                    value: model.launchAtLogin.statusDescription,
                    isOK: model.launchAtLogin.status == .enabled
                )
                HStack {
                    Button("Accessibility Settings…") { model.permissions.open(.accessibility) }
                    Button("Automation Settings…") { model.permissions.open(.automation) }
                    Spacer()
                    Button("Refresh") {
                        model.permissions.refreshAll()
                        model.launchAtLogin.refresh()
                    }
                }
                .controlSize(.small)
            }

            Section("Diagnostics") {
                DiagnosticsSummary()
                EventLogView()
                HStack {
                    Button("Copy Diagnostics") { copyDiagnostics() }
                    Button("Clear Log") { model.log.clear() }
                }
                .controlSize(.small)
            }

            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("AlcoveInspired stores its settings only on this Mac (UserDefaults). It sends no telemetry and makes no network requests except loading Spotify artwork, which can be turned off.")
            }
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.settings.resetToDefaults() }
        }
    }

    private func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(DiagnosticsReport.make(model: model), forType: .string)
    }
}

private struct DiagnosticsSummary: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let coordinator = model.coordinator
        let metrics = coordinator.metrics
        let activities = coordinator.controller.activities
        VStack(alignment: .leading, spacing: 4) {
            row("Display", metrics.hasNotch
                ? "Notch \(Int(metrics.notchSize.width))×\(Int(metrics.notchSize.height)) pt"
                : "No notch (fallback \(Int(metrics.notchSize.width))×\(Int(metrics.notchSize.height)) pt)")
            row("Screen width", "\(Int(metrics.screenWidth)) pt")
            row("Island state", describe(coordinator.presentation))
            row("Live activities", activities.liveActivities.keys.map(\.rawValue).sorted().joined(separator: ", ").ifEmpty("none"))
            row("Queued", "\(activities.queuedActivities.count)")
            row("Media keys", "\(model.mediaKeyState)")
        }
        .font(.system(size: 11.5).monospaced())
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private func describe(_ presentation: IslandPresentation) -> String {
        switch presentation {
        case .hidden: return "hidden"
        case let .idle(hovered): return hovered ? "idle (hover)" : "idle"
        case let .compact(activity, _): return "compact · \(activity.id)"
        case let .banner(activity, _): return "banner · \(activity.id)"
        case let .expanded(context): return "expanded · \(context.tab?.rawValue ?? "none")\(context.isPinned ? " · pinned" : "")"
        }
    }
}

private struct EventLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Reading the revision subscribes the view to log changes.
        let _ = model.logRevision
        let entries = Array(model.log.entries.suffix(60).reversed())
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if entries.isEmpty {
                    Text("No events yet").foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Text(entry.category)
                            .foregroundStyle(.tint)
                            .frame(width: 52, alignment: .leading)
                        Text(entry.message)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11).monospaced())
        .frame(height: 150)
    }
}

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    static var hardwareModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

enum DiagnosticsReport {
    @MainActor
    static func make(model: AppModel) -> String {
        let metrics = model.coordinator.metrics
        var lines = [
            "AlcoveInspired \(AppInfo.version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(AppInfo.hardwareModel)",
            "Notch: \(metrics.hasNotch) \(metrics.notchSize.width)x\(metrics.notchSize.height), screen width \(metrics.screenWidth)",
            "Accessibility: \(model.permissions.isAccessibilityTrusted)",
            "Automation: " + MusicSourceKind.allCases.map { "\($0.displayName)=\(model.permissions.automation[$0]?.title ?? "?")" }.joined(separator: ", "),
            "Notifications: \(model.permissions.notifications.title)",
            "Launch at login: \(model.launchAtLogin.statusDescription)",
            "Media keys: \(model.mediaKeyState)",
            "Brightness available: \(model.brightness.isAvailable), settable: \(model.brightness.canSetBrightness)",
            "Volume output: \(model.volume.deviceName ?? "none"), settable: \(model.volume.canSetVolume)",
            "",
            "Recent events:",
        ]
        for entry in model.log.entries.suffix(100) {
            lines.append("\(entry.date.ISO8601Format()) [\(entry.category)] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
