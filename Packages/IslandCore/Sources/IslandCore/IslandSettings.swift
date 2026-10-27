import Foundation
#if canImport(CoreGraphics)
// On Apple platforms CGRect/CGSize initializers and Equatable live in the
// CoreGraphics overlay, which Foundation no longer re-exports.
import CoreGraphics
#endif

public enum DisplayTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Built-in display with a notch if present, otherwise the main display.
    case automatic
    /// Always the display with the menu bar / keyboard focus.
    case mainDisplay

    public var id: String { rawValue }
}

public enum IslandSizeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large

    public var id: String { rawValue }

    public var scale: CGFloat {
        switch self {
        case .compact: return 0.9
        case .standard: return 1.0
        case .large: return 1.12
        }
    }
}

public enum AccentOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case white
    case artwork
    case blue
    case purple
    case pink
    case orange
    case green
    case teal

    public var id: String { rawValue }
}

public enum ThemeOption: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }
}

public enum HUDStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Icon and level beside the notch, island keeps the notch height.
    case compact
    /// The island drops below the notch with a larger bar.
    case banner

    public var id: String { rawValue }
}

public enum MusicSourcePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case appleMusic
    case spotify

    public var id: String { rawValue }
}

/// All user settings. Stored as one JSON document (see `SettingsPersistence`);
/// every field has a default so older or partial documents still load.
public struct IslandSettings: Codable, Equatable, Sendable {
    public struct General: Codable, Equatable, Sendable {
        public var isEnabled = true
        public var displayTarget: DisplayTarget = .automatic
        public var hoverBehavior: HoverBehavior = .expand
        public var hoverDelay: Double = 0.3
        public var collapseOnExit = true
        public var collapseDelay: Double = 0.45
        public var isPinned = false
        public var hideInFullscreen = false
        public var showLiveActivities = true
        public var swipeGestures = true
        public var hapticFeedback = true
        public var showMenuBarIcon = true
        public var fallbackIdleVisible = true
        public init() {}
    }

    public struct Appearance: Codable, Equatable, Sendable {
        public var size: IslandSizeOption = .standard
        public var cornerRadius: Double = 24
        /// Multiplier: >1 is faster, <1 is slower.
        public var animationSpeed: Double = 1.0
        public var secondaryOpacity: Double = 0.6
        public var accent: AccentOption = .system
        public var settingsTheme: ThemeOption = .system
        public var showShadow = true
        public init() {}
    }

    public struct Music: Codable, Equatable, Sendable {
        public var isEnabled = true
        public var preferredSource: MusicSourcePreference = .automatic
        public var showCompact = true
        public var peekOnTrackChange = true
        /// Seconds a paused player stays in the compact island (0 = hide at once).
        public var pausedTimeout: Double = 30
        /// Spotify artwork is only available as an https URL.
        public var loadRemoteArtwork = true
        public var showPlaybackIndicator = true
        public init() {}
    }

    public struct LevelHUD: Codable, Equatable, Sendable {
        public var isEnabled = true
        public var duration: Double = 1.6
        public var style: HUDStyle = .compact
        public init() {}
    }

    public struct Volume: Codable, Equatable, Sendable {
        public var hud = LevelHUD()
        public var showOutputDeviceChanges = true
        public init() {}
    }

    public struct MediaKeys: Codable, Equatable, Sendable {
        /// Intercept volume/brightness keys (requires Accessibility access)
        /// so that only the island HUD appears.
        public var replaceSystemHUD = false
        public init() {}
    }

    public struct Timer: Codable, Equatable, Sendable {
        public var isEnabled = true
        public var defaultDuration: Double = 300
        public var playSound = true
        public var systemNotification = true
        public var showCompact = true
        public init() {}
    }

    public struct Notifications: Codable, Equatable, Sendable {
        public var isEnabled = true
        public var duration: Double = 4
        public init() {}
    }

    public struct Power: Codable, Equatable, Sendable {
        public var isEnabled = true
        public var showChargingChanges = true
        public var lowBatteryThreshold: Int = 20
        public init() {}
    }

    public var general = General()
    public var appearance = Appearance()
    public var music = Music()
    public var volume = Volume()
    public var brightness = LevelHUD()
    public var mediaKeys = MediaKeys()
    public var timer = Timer()
    public var notifications = Notifications()
    public var power = Power()

    public init() {}

    public static let `default` = IslandSettings()

    /// Clamps every numeric value into its supported range.
    public func sanitized() -> IslandSettings {
        var copy = self
        copy.general.hoverDelay = Self.clamp(general.hoverDelay, 0, 2)
        copy.general.collapseDelay = Self.clamp(general.collapseDelay, 0, 3)
        copy.appearance.cornerRadius = Self.clamp(appearance.cornerRadius, 12, 36)
        copy.appearance.animationSpeed = Self.clamp(appearance.animationSpeed, 0.5, 1.6)
        copy.appearance.secondaryOpacity = Self.clamp(appearance.secondaryOpacity, 0.3, 0.9)
        copy.music.pausedTimeout = Self.clamp(music.pausedTimeout, 0, 600)
        copy.volume.hud.duration = Self.clamp(volume.hud.duration, 0.8, 6)
        copy.brightness.duration = Self.clamp(brightness.duration, 0.8, 6)
        copy.timer.defaultDuration = CountdownTimer.clampDuration(timer.defaultDuration)
        copy.notifications.duration = Self.clamp(notifications.duration, 2, 15)
        copy.power.lowBatteryThreshold = min(max(power.lowBatteryThreshold, 5), 50)
        return copy
    }

    /// Pages the expanded island offers with these settings.
    public var availableTabs: [IslandTab] {
        var tabs: [IslandTab] = []
        if music.isEnabled { tabs.append(.music) }
        if timer.isEnabled { tabs.append(.timer) }
        return tabs
    }

    public var layoutConfig: IslandLayoutConfig {
        IslandLayoutConfig(
            scale: appearance.size.scale,
            expandedCornerRadius: CGFloat(appearance.cornerRadius),
            fallbackIdleVisible: general.fallbackIdleVisible
        )
    }

    public var controllerBehavior: IslandController.Behavior {
        IslandController.Behavior(
            hover: general.hoverBehavior,
            hoverExpandDelay: general.hoverDelay,
            collapseDelay: general.collapseDelay,
            collapseOnExit: general.collapseOnExit,
            showLiveActivities: general.showLiveActivities,
            swipeGestures: general.swipeGestures,
            availableTabs: availableTabs
        )
    }

    /// Whether events of a module should reach the island.
    public func isModuleEnabled(_ kind: ActivityKind) -> Bool {
        switch kind {
        case .music: return music.isEnabled
        case .timer: return timer.isEnabled
        case .volume: return volume.hud.isEnabled
        case .brightness: return brightness.isEnabled
        case .power: return power.isEnabled
        case .notification: return notifications.isEnabled
        }
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        guard value.isFinite else { return lower }
        return min(max(value, lower), upper)
    }
}

/// Loads and stores `IslandSettings` in `UserDefaults` as a JSON document.
///
/// Decoding is tolerant: missing keys take default values, unknown keys are
/// ignored, and a section that cannot be decoded (e.g. an enum value from a
/// newer version) falls back to its defaults without losing other sections.
public final class SettingsPersistence {
    public static let storageKey = "island.settings.v1"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = SettingsPersistence.storageKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> IslandSettings {
        guard let data = defaults.data(forKey: key) else { return .default }
        return Self.decode(data)
    }

    public func save(_ settings: IslandSettings) {
        guard let data = try? Self.encoder.encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    public func reset() {
        defaults.removeObject(forKey: key)
    }

    public static func decode(_ data: Data) -> IslandSettings {
        guard
            let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let defaultData = try? encoder.encode(IslandSettings.default),
            let defaultObject = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any]
        else {
            return .default
        }

        // Fast path: everything decodes after filling in missing keys.
        if let settings = decodeObject(merge(defaultObject, stored)) {
            return settings.sanitized()
        }

        // Slow path: keep only the sections that decode on their own.
        var result = defaultObject
        for (sectionKey, value) in stored where defaultObject[sectionKey] != nil {
            var candidate = defaultObject
            candidate[sectionKey] = mergeValue(defaultObject[sectionKey], value)
            if decodeObject(candidate) != nil {
                result[sectionKey] = candidate[sectionKey]
            }
        }
        return (decodeObject(result) ?? .default).sanitized()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func decodeObject(_ object: [String: Any]) -> IslandSettings? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(IslandSettings.self, from: data)
    }

    private static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay where base[key] != nil {
            result[key] = mergeValue(base[key], value)
        }
        return result
    }

    private static func mergeValue(_ base: Any?, _ overlay: Any) -> Any {
        if let baseDict = base as? [String: Any], let overlayDict = overlay as? [String: Any] {
            return merge(baseDict, overlayDict)
        }
        return overlay
    }
}
