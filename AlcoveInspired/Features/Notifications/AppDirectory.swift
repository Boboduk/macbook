import AppKit

/// Resolves a bundle identifier to a human-readable app name and its icon,
/// with a small cache. Used for mirrored notifications (the app that sent
/// them) in both the settings list and the banner.
@MainActor
final class AppDirectory {
    static let shared = AppDirectory()

    private var names: [String: String] = [:]
    private let iconCache = NSCache<NSString, NSImage>()

    private init() {
        iconCache.countLimit = 32
    }

    func name(for bundleIdentifier: String) -> String {
        if let cached = names[bundleIdentifier] { return cached }
        let resolved = Self.lookUpName(bundleIdentifier) ?? bundleIdentifier
        names[bundleIdentifier] = resolved
        return resolved
    }

    func icon(for bundleIdentifier: String) -> NSImage? {
        guard !bundleIdentifier.isEmpty else { return nil }
        if let cached = iconCache.object(forKey: bundleIdentifier as NSString) { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        iconCache.setObject(icon, forKey: bundleIdentifier as NSString)
        return icon
    }

    private static func lookUpName(_ bundleIdentifier: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        if let bundle = Bundle(url: url) {
            let info = bundle.infoDictionary
            if let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (info?["CFBundleName"] as? String), !display.isEmpty {
                return display
            }
        }
        // Fall back to the file name without the ".app" extension.
        let name = FileManager.default.displayName(atPath: url.path)
        return name.isEmpty ? nil : (name as NSString).deletingPathExtension
    }
}
