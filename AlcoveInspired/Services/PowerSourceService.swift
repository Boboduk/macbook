import Foundation
import IOKit.ps
import IslandCore

/// Battery and charger state through the public IOKit power sources API.
/// Event driven: `IOPSNotificationCreateRunLoopSource` calls back whenever a
/// power source changes (plugging in, percentage steps).
@MainActor
final class PowerSourceService {
    var onChange: ((PowerState) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(powerSourceCallback, context)?.takeRetainedValue() else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    fileprivate func sourcesChanged() {
        onChange?(Self.currentState())
    }

    static func currentState() -> PowerState {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .noBattery }

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let isPluggedIn = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return PowerState(hasBattery: true, percent: percent, isCharging: isCharging, isPluggedIn: isPluggedIn)
        }
        return .noBattery
    }
}

/// C callback; the run loop source lives on the main run loop.
private func powerSourceCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    MainActor.assumeIsolated {
        Unmanaged<PowerSourceService>.fromOpaque(context).takeUnretainedValue().sourcesChanged()
    }
}
