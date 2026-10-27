#if DEBUG
import Foundation
import IslandCore

/// Debug-only launch hook used by `Scripts/ci-smoke-test.sh` to put the island
/// into a given state for screenshots: `--ui-test-state <state>`.
/// Not compiled into Release builds.
@MainActor
enum UITestHooks {
    static func apply(to model: AppModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-test-state"), index + 1 < arguments.count else { return }
        let state = arguments[index + 1]
        model.log.append("test", "ui test state \(state)")
        // Long display times so the screenshot catches transient states.
        model.settings.update { settings in
            settings.volume.hud.duration = 6
            settings.brightness.duration = 6
            settings.notifications.duration = 15
            settings.general.hoverBehavior = .highlight
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            run(state, model: model)
        }
    }

    private static func run(_ state: String, model: AppModel) {
        switch state {
        case "expanded-music":
            model.coordinator.expand(tab: .music)
        case "expanded-timer":
            model.timer.startCountdown(duration: 300)
            model.coordinator.expand(tab: .timer)
        case "hud-volume":
            model.coordinator.post(.volumeChanged(level: 0.62, muted: false, device: nil))
        case "hud-brightness":
            model.coordinator.post(.brightnessChanged(level: 0.4))
        case "banner-notice":
            model.notifications.post(Notice(
                id: "ui-test",
                symbol: "bell.fill",
                title: "Island notification",
                body: "Banner presentation below the notch"
            ))
        case "timer-compact":
            model.timer.startCountdown(duration: 754)
        case "settings":
            model.showSettings()
        default:
            break
        }
    }
}
#endif
