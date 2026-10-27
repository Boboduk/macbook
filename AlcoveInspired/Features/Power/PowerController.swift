import Foundation
import IslandCore
import Observation

/// Battery state and charger events (plugged in, unplugged, low, full).
@MainActor
@Observable
final class PowerController {
    private(set) var state: PowerState = .noBattery

    @ObservationIgnored var onEvent: ((IslandEvent) -> Void)?
    @ObservationIgnored private let service = PowerSourceService()
    @ObservationIgnored private var settings: IslandSettings.Power
    @ObservationIgnored private var lastState: PowerState?
    @ObservationIgnored private var isStarted = false

    init(settings: IslandSettings.Power) {
        self.settings = settings
    }

    var hasBattery: Bool { state.hasBattery }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        service.onChange = { [weak self] state in self?.update(state) }
        service.start()
        // The first reading never produces an event (no HUD at launch).
        update(PowerSourceService.currentState())
    }

    func stop() {
        service.stop()
        isStarted = false
        lastState = nil
    }

    func apply(settings new: IslandSettings.Power) {
        settings = new
        if new.isEnabled && !isStarted {
            start()
        } else if !new.isEnabled && isStarted {
            stop()
        }
    }

    private func update(_ new: PowerState) {
        state = new
        let change = PowerTransition.change(from: lastState, to: new, lowThreshold: settings.lowBatteryThreshold)
        lastState = new
        if let change {
            onEvent?(.power(new, change))
        }
    }
}
