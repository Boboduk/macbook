import Foundation

/// Runs AppleScript off the main thread so a slow or busy player can never
/// stall the island's animations. Scripts are compiled once and cached; all
/// scripting happens on one serial queue (AppleScript is thread-safe since
/// macOS 10.6 as long as a script instance stays on one thread).
final class AppleScriptRunner: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case compile(String)
        case execution(code: Int, message: String)

        /// -1743: the user denied Automation access (errAEEventNotPermitted).
        var isPermissionDenied: Bool {
            if case let .execution(code, _) = self { return code == -1743 || code == -1744 }
            return false
        }

        /// -600: the target app is not running (procNotFound).
        var isAppNotRunning: Bool {
            if case let .execution(code, _) = self { return code == -600 }
            return false
        }

        var message: String {
            switch self {
            case let .compile(message): return message
            case let .execution(code, message): return message.isEmpty ? "AppleScript error \(code)" : message
            }
        }
    }

    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "io.github.boboduk.AlcoveInspired.applescript", qos: .userInitiated)
    /// Accessed only on `queue`.
    private var cache: [String: NSAppleScript] = [:]

    /// Executes `source` and calls `completion` on the main queue.
    /// Pass `cacheable: false` for one-off scripts with embedded values
    /// (e.g. a seek position) so the cache stays bounded.
    func run(_ source: String, cacheable: Bool = true, completion: @escaping (Result<NSAppleEventDescriptor, Failure>) -> Void) {
        queue.async { [self] in
            let result = execute(source, cacheable: cacheable)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    private func execute(_ source: String, cacheable: Bool) -> Result<NSAppleEventDescriptor, Failure> {
        let script: NSAppleScript
        if let cached = cache[source] {
            script = cached
        } else {
            guard let created = NSAppleScript(source: source) else {
                return .failure(.compile("Could not create the script"))
            }
            var compileError: NSDictionary?
            guard created.compileAndReturnError(&compileError) else {
                return .failure(.compile(compileError?[NSAppleScript.errorMessage] as? String ?? "Could not compile the script"))
            }
            if cacheable {
                cache[source] = created
            }
            script = created
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            return .failure(.execution(code: code, message: message))
        }
        return .success(output)
    }
}

/// Four-character Apple Event type codes used when reading script results.
/// Declared here as `DescType` values to avoid depending on how the SDK
/// imports the C enum constants.
enum AEType {
    static let unicodeText = code("utxt")
    static let utf8Text = code("utf8")
    static let text = code("TEXT")
    static let float64 = code("doub")
    static let float32 = code("sing")
    static let sint16 = code("shor")
    static let sint32 = code("long")
    static let sint64 = code("comp")
    static let uint32 = code("magn")
    static let trueValue = code("true")
    static let falseValue = code("fals")
    static let boolean = code("bool")
    static let list = code("list")
    static let null = code("null")
    /// Wildcard event class / id ('****').
    static let wildcard = code("****")

    static func code(_ string: String) -> DescType {
        string.utf8.reduce(DescType(0)) { ($0 << 8) | DescType($1) }
    }
}

extension NSAppleEventDescriptor {
    /// Items of a list descriptor converted to Swift values
    /// (`String`, `Double`, `Bool`) — `nil` for anything else.
    var listValues: [Any?] {
        guard descriptorType == AEType.list, numberOfItems > 0 else { return [] }
        return (1...numberOfItems).map { index in
            atIndex(index)?.swiftValue
        }
    }

    var swiftValue: Any? {
        switch descriptorType {
        case AEType.unicodeText, AEType.utf8Text, AEType.text:
            return stringValue
        case AEType.float64, AEType.float32, AEType.sint16, AEType.sint32, AEType.sint64, AEType.uint32:
            return doubleValue
        case AEType.trueValue:
            return true
        case AEType.falseValue:
            return false
        case AEType.boolean:
            return booleanValue
        default:
            return nil
        }
    }
}
