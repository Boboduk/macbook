import Foundation

/// Special keys delivered as `NX_SYSDEFINED` events with subtype 8
/// (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`). Codes from IOKit `ev_keymap.h`.
public enum MediaKey: Int, Equatable, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case play = 16
    case next = 17
    case previous = 18
    case fast = 19
    case rewind = 20
    case illuminationUp = 21
    case illuminationDown = 22

    public var isVolumeKey: Bool { self == .soundUp || self == .soundDown || self == .mute }
    public var isBrightnessKey: Bool { self == .brightnessUp || self == .brightnessDown }
}

public struct MediaKeyEvent: Equatable, Sendable {
    public static let auxControlButtonsSubtype = 8

    public var key: MediaKey
    public var isKeyDown: Bool
    public var isRepeat: Bool

    public init(key: MediaKey, isKeyDown: Bool, isRepeat: Bool) {
        self.key = key
        self.isKeyDown = isKeyDown
        self.isRepeat = isRepeat
    }

    /// Decodes `NSEvent.subtype` / `NSEvent.data1` of a system-defined event.
    /// data1 layout: key code in bits 16–31, key state in bits 8–15
    /// (0x0A down, 0x0B up), repeat flag in bit 0.
    public init?(subtype: Int, data1: Int) {
        guard subtype == MediaKeyEvent.auxControlButtonsSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0x0000_FFFF
        let state = (flags & 0xFF00) >> 8
        guard let key = MediaKey(rawValue: keyCode), state == 0x0A || state == 0x0B else { return nil }
        self.key = key
        self.isKeyDown = state == 0x0A
        self.isRepeat = (flags & 0x1) == 1
    }
}

/// Step logic matching the system: 16 steps, or 64 with Option+Shift.
public enum LevelStepper {
    public static func step(_ value: Double, up: Bool, fine: Bool) -> Double {
        let steps: Double = fine ? 64 : 16
        let current = min(max(value, 0), 1) * steps
        // Snap to the grid first so that odd values do not accumulate drift.
        let snapped = up ? (current + 0.001).rounded(.down) : (current - 0.001).rounded(.up)
        let next = up ? snapped + 1 : snapped - 1
        return min(max(next / steps, 0), 1)
    }
}

/// Turns a stream of scroll events over the island into at most one swipe
/// per gesture.
public struct ScrollGestureRecognizer {
    public enum Phase: Equatable {
        /// Precise (trackpad) gesture phases.
        case began, changed, ended, cancelled
        /// Inertial scrolling after the fingers lifted — ignored.
        case momentum
        /// Mouse wheel: no phase information.
        case none
    }

    /// Points of finger travel needed for a trackpad swipe.
    public var threshold: Double
    /// Minimum seconds between two mouse-wheel swipes.
    public var wheelInterval: TimeInterval

    private var accumulatedX: Double = 0
    private var accumulatedY: Double = 0
    private var didFire = false
    private var lastWheelFire: TimeInterval = -.infinity

    public init(threshold: Double = 34, wheelInterval: TimeInterval = 0.4) {
        self.threshold = threshold
        self.wheelInterval = wheelInterval
    }

    /// - Parameters:
    ///   - deltaX/deltaY: `NSEvent.scrollingDeltaX/Y`.
    ///   - isInverted: `NSEvent.isDirectionInvertedFromDevice` ("natural" scrolling).
    ///   - timestamp: `NSEvent.timestamp`, used for mouse wheel rate limiting.
    /// - Returns: the swipe direction of the *fingers* (or wheel), once per gesture.
    public mutating func handle(phase: Phase, deltaX: Double, deltaY: Double, isInverted: Bool, timestamp: TimeInterval) -> SwipeDirection? {
        // Convert content deltas into finger movement (right/down positive).
        let fingerX = isInverted ? deltaX : -deltaX
        let fingerY = isInverted ? deltaY : -deltaY

        switch phase {
        case .began:
            reset()
            accumulate(fingerX, fingerY)
            return fireIfNeeded()
        case .changed:
            accumulate(fingerX, fingerY)
            return fireIfNeeded()
        case .ended, .cancelled:
            reset()
            return nil
        case .momentum:
            return nil
        case .none:
            guard timestamp - lastWheelFire >= wheelInterval else { return nil }
            guard let direction = Self.direction(x: fingerX, y: fingerY, minimum: 0.5) else { return nil }
            lastWheelFire = timestamp
            return direction
        }
    }

    public mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        didFire = false
    }

    private mutating func accumulate(_ x: Double, _ y: Double) {
        accumulatedX += x
        accumulatedY += y
    }

    private mutating func fireIfNeeded() -> SwipeDirection? {
        guard !didFire, let direction = Self.direction(x: accumulatedX, y: accumulatedY, minimum: threshold) else { return nil }
        didFire = true
        return direction
    }

    /// Dominant-axis direction if it is clearly dominant and long enough.
    static func direction(x: Double, y: Double, minimum: Double) -> SwipeDirection? {
        let absX = abs(x)
        let absY = abs(y)
        if absX >= minimum && absX > absY * 1.5 { return x > 0 ? .right : .left }
        if absY >= minimum && absY > absX * 1.5 { return y > 0 ? .down : .up }
        return nil
    }
}
