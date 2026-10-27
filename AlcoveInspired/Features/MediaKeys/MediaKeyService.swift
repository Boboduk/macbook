import AppKit
import CoreGraphics
import IslandCore

/// Watches the volume and brightness keys through a session event tap.
///
/// * **Observe** mode (Accessibility granted, "Replace system HUD" off):
///   keys pass through unchanged; brightness key presses trigger the
///   brightness HUD (there is no brightness-change notification).
/// * **Replace** mode: volume and brightness keys are consumed and the app
///   changes the levels itself, so only the island HUD appears.
///
/// Creating an event tap requires Accessibility access. Without it the
/// service stays off and the volume HUD still works through CoreAudio.
@MainActor
final class MediaKeyService {
    enum State: Equatable {
        case off
        case needsPermission
        case observing
        case replacing
    }

    private(set) var state: State = .off
    var onStateChange: ((State) -> Void)?

    /// Return `true` if the key was handled (and must be consumed in replace mode).
    var volumeHandler: ((MediaKeyEvent, _ fine: Bool) -> Bool)?
    var brightnessHandler: ((MediaKeyEvent, _ fine: Bool) -> Bool)?
    /// Brightness key pressed in observe mode.
    var brightnessObserved: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wantsTap = false
    private var replaceSystemHUD = false

    /// - Parameters:
    ///   - wanted: some feature needs key events (brightness HUD or replace mode).
    ///   - replace: consume volume/brightness keys.
    ///   - trusted: Accessibility permission is granted.
    func configure(wanted: Bool, replace: Bool, trusted: Bool) {
        wantsTap = wanted
        replaceSystemHUD = replace
        if wanted && trusted {
            installTapIfNeeded()
        } else {
            removeTap()
        }
        let newState: State
        if !wanted {
            newState = .off
        } else if tap == nil {
            newState = .needsPermission
        } else {
            newState = replace ? .replacing : .observing
        }
        if newState != state {
            state = newState
            onStateChange?(newState)
        }
    }

    func stop() {
        removeTap()
        state = .off
    }

    /// After wake the system may have disabled the tap.
    func revalidate() {
        guard let tap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Tap

    private func installTapIfNeeded() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(MediaKeyService.systemDefinedEventType)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: mediaKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    /// `NX_SYSDEFINED`
    nonisolated static let systemDefinedEventType: UInt32 = 14

    /// Returns `true` when the event must be consumed.
    fileprivate func shouldConsume(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard type.rawValue == MediaKeyService.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              let keyEvent = MediaKeyEvent(subtype: Int(nsEvent.subtype.rawValue), data1: nsEvent.data1)
        else {
            return false
        }
        let fine = nsEvent.modifierFlags.contains([.option, .shift])

        if keyEvent.key.isBrightnessKey {
            if replaceSystemHUD, let brightnessHandler, brightnessHandler(keyEvent, fine) {
                return true
            }
            if keyEvent.isKeyDown {
                brightnessObserved?()
            }
            return false
        }
        if keyEvent.key.isVolumeKey, replaceSystemHUD, let volumeHandler {
            return volumeHandler(keyEvent, fine)
        }
        return false
    }
}

/// C callback of the event tap. The tap's run loop source is on the main run
/// loop, so the callback runs on the main thread.
private func mediaKeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let consume = MainActor.assumeIsolated {
        let service = Unmanaged<MediaKeyService>.fromOpaque(userInfo).takeUnretainedValue()
        return service.shouldConsume(type: type, event: event)
    }
    return consume ? nil : Unmanaged.passUnretained(event)
}
