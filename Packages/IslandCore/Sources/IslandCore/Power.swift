import Foundation

public struct PowerState: Equatable, Sendable {
    public var hasBattery: Bool
    /// 0...100
    public var percent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool

    public init(hasBattery: Bool, percent: Int, isCharging: Bool, isPluggedIn: Bool) {
        self.hasBattery = hasBattery
        self.percent = min(max(percent, 0), 100)
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
    }

    public static let noBattery = PowerState(hasBattery: false, percent: 100, isCharging: false, isPluggedIn: true)
}

public enum PowerChange: Equatable, Sendable {
    case pluggedIn
    case unplugged
    case lowBattery
    case fullyCharged
}

public enum PowerTransition {
    /// Detects the user-visible change between two consecutive readings.
    /// The first reading (`old == nil`) never produces an event, so launching
    /// the app does not show a "charging" HUD.
    public static func change(from old: PowerState?, to new: PowerState, lowThreshold: Int) -> PowerChange? {
        guard let old, new.hasBattery, old.hasBattery else { return nil }
        if !old.isPluggedIn && new.isPluggedIn { return .pluggedIn }
        if old.isPluggedIn && !new.isPluggedIn { return .unplugged }
        if !new.isPluggedIn && old.percent > lowThreshold && new.percent <= lowThreshold { return .lowBattery }
        if new.isPluggedIn && old.percent < 100 && new.percent >= 100 { return .fullyCharged }
        return nil
    }
}
