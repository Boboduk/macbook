import CoreGraphics
import Darwin
import Foundation

/// Built-in display brightness.
///
/// macOS has no public API to read or change the brightness of the built-in
/// display on Apple silicon Macs (every Mac with a notch). The system's own
/// brightness controls use the `DisplayServices` framework. It is loaded
/// dynamically with `dlopen` — nothing is linked at build time — and only
/// the two well-known functions are used. If they are missing, the feature
/// reports itself as unavailable instead of failing.
final class BrightnessService {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFunction: GetBrightness?
    private let setFunction: SetBrightness?

    init() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        if let handle = dlopen(path, RTLD_LAZY) {
            getFunction = dlsym(handle, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
            setFunction = dlsym(handle, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        } else {
            getFunction = nil
            setFunction = nil
        }
    }

    var canRead: Bool { getFunction != nil && builtInDisplay() != nil }
    var canWrite: Bool { setFunction != nil && builtInDisplay() != nil }

    /// The built-in panel, if one is active (lid open).
    func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    func brightness() -> Double? {
        guard let getFunction, let display = builtInDisplay() else { return nil }
        var value: Float = 0
        guard getFunction(display, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    @discardableResult
    func setBrightness(_ level: Double) -> Bool {
        guard let setFunction, let display = builtInDisplay() else { return false }
        return setFunction(display, Float(min(max(level, 0), 1))) == 0
    }
}
