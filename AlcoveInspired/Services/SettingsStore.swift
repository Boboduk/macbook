import Foundation
import IslandCore
import Observation

/// Observable wrapper around `IslandSettings`, persisted on every change.
///
/// Views bind to `settings` (`$store.settings.music.isEnabled`); services
/// subscribe with `observe(_:)` to react to the changes that concern them.
@MainActor
@Observable
final class SettingsStore {
    /// Backing storage tracked by Observation.
    private var storage: IslandSettings

    @ObservationIgnored private let persistence: SettingsPersistence
    @ObservationIgnored private var observers: [(IslandSettings, IslandSettings) -> Void] = []

    init(persistence: SettingsPersistence = SettingsPersistence()) {
        self.persistence = persistence
        self.storage = persistence.load()
    }

    var settings: IslandSettings {
        get { storage }
        set { apply(newValue) }
    }

    /// Registers a handler called with `(new, old)` after every change.
    func observe(_ handler: @escaping (_ new: IslandSettings, _ old: IslandSettings) -> Void) {
        observers.append(handler)
    }

    func update(_ change: (inout IslandSettings) -> Void) {
        var copy = storage
        change(&copy)
        apply(copy)
    }

    func resetToDefaults() {
        persistence.reset()
        apply(.default)
    }

    private func apply(_ newValue: IslandSettings) {
        let sanitized = newValue.sanitized()
        guard sanitized != storage else { return }
        let old = storage
        storage = sanitized
        persistence.save(sanitized)
        for observer in observers {
            observer(sanitized, old)
        }
    }
}
