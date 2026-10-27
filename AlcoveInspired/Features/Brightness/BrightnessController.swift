import Foundation
import IslandCore
import Observation

/// Brightness state for the UI and the island HUD.
///
/// There is no notification for brightness changes. The HUD is driven by the
/// brightness keys (seen through `MediaKeyService`, which needs Accessibility
/// access): after a key press the level is read a few times while the system
/// animates to the new value. No continuous polling.
@MainActor
@Observable
final class BrightnessController {
    private(set) var level: Double = 0
    private(set) var isAvailable = false
    private(set) var canSetBrightness = false

    @ObservationIgnored var onEvent: ((IslandEvent) -> Void)?
    @ObservationIgnored private let service = BrightnessService()
    @ObservationIgnored private var followUp: Task<Void, Never>?

    func start() {
        refreshAvailability()
        if let value = service.brightness() {
            level = value
        }
    }

    func refreshAvailability() {
        isAvailable = service.canRead
        canSetBrightness = service.canWrite
    }

    /// Reads the level now and while the system animates the change, then
    /// shows the HUD. Bounded: three reads within half a second.
    func brightnessKeyPressed() {
        followUp?.cancel()
        followUp = Task { [weak self] in
            for delay in [40, 180, 450] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.readAndPublish(force: delay == 40)
            }
        }
    }

    /// Handles an intercepted brightness key (when replacing the system HUD).
    /// Returns `false` if brightness cannot be changed, so the key should
    /// reach the system instead.
    func step(up: Bool, fine: Bool) -> Bool {
        guard canSetBrightness, let current = service.brightness() else { return false }
        let target = LevelStepper.step(current, up: up, fine: fine)
        service.setBrightness(target)
        level = target
        onEvent?(.brightnessChanged(level: target))
        return true
    }

    func setLevel(_ value: Double) {
        guard canSetBrightness else { return }
        service.setBrightness(value)
        level = value
        onEvent?(.brightnessChanged(level: value))
    }

    private func readAndPublish(force: Bool) {
        guard let value = service.brightness() else {
            isAvailable = false
            return
        }
        let changed = abs(value - level) > 0.001
        level = value
        if changed || force {
            onEvent?(.brightnessChanged(level: value))
        }
    }
}
