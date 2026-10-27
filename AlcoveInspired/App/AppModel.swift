import AppKit
import IslandCore
import Observation
import SwiftUI

/// Composition root: creates the services and controllers once, wires them
/// together and exposes them to SwiftUI through the environment.
///
/// Data flow:
/// ```
/// feature controllers ──IslandEvent──▶ IslandCoordinator ─▶ EventRouter ─▶ ActivityManager
///                                             │                                │
///          SwiftUI views ◀── presentation ────┴──── IslandController ◀─────────┘
/// ```
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let coordinator: IslandCoordinator
    let log: DiagnosticsLog
    let permissions: PermissionService
    let launchAtLogin: LaunchAtLoginService
    let music: MusicController
    let volume: VolumeController
    let brightness: BrightnessController
    let timer: TimerController
    let power: PowerController

    /// Mirrors `MediaKeyService.State` for the settings UI.
    private(set) var mediaKeyState: MediaKeyService.State = .off
    /// Monotonic counter bumped on diagnostics log changes (for the System pane).
    private(set) var logRevision = 0

    @ObservationIgnored let notifications: NotificationService
    @ObservationIgnored private let mediaKeys = MediaKeyService()
    @ObservationIgnored private var windowController: IslandWindowController?
    @ObservationIgnored private var statusItem: StatusItemController?
    @ObservationIgnored private var settingsWindow: SettingsWindowController?
    @ObservationIgnored private var workspaceTokens: [NSObjectProtocol] = []
    @ObservationIgnored private var started = false

    init() {
        let settings = SettingsStore()
        let current = settings.settings
        let log = DiagnosticsLog()
        let permissions = PermissionService()

        self.settings = settings
        self.log = log
        self.permissions = permissions
        self.coordinator = IslandCoordinator(settings: current, log: log)
        self.launchAtLogin = LaunchAtLoginService()
        self.music = MusicController(settings: current.music, permissions: permissions)
        self.volume = VolumeController(settings: current.volume)
        self.brightness = BrightnessController()
        self.timer = TimerController(settings: current.timer)
        self.power = PowerController(settings: current.power)
        self.notifications = NotificationService(permissions: permissions, timerSettings: current.timer)
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        let current = settings.settings

        wireEvents()

        let windowController = IslandWindowController(
            coordinator: coordinator,
            settings: settings,
            rootView: IslandRootView(model: self)
        )
        windowController.contextMenuProvider = { [weak self] in self?.makeContextMenu() }
        windowController.onWake = { [weak self] in self?.handleWake() }
        self.windowController = windowController
        windowController.start()

        permissions.onAccessibilityChange = { [weak self] _ in self?.configureMediaKeys() }
        permissions.start()
        notifications.start()
        volume.start()
        brightness.start()
        timer.restore()
        if current.music.isEnabled { music.start() }
        if current.power.isEnabled { power.start() }
        configureMediaKeys()

        settings.observe { [weak self] new, old in
            self?.settingsChanged(new, old: old)
        }
        log.onChange = { [weak self] in self?.logRevision &+= 1 }
        updateStatusItem()
        log.append("app", "started")
        #if DEBUG
        UITestHooks.apply(to: self)
        #endif
    }

    func stop() {
        windowController?.stop()
        music.stop()
        volume.stop()
        power.stop()
        mediaKeys.stop()
        permissions.stop()
        for token in workspaceTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceTokens.removeAll()
    }

    private func wireEvents() {
        let post: (IslandEvent) -> Void = { [weak self] event in self?.coordinator.post(event) }
        music.onEvent = post
        volume.onEvent = post
        brightness.onEvent = post
        timer.onEvent = post
        power.onEvent = post
        notifications.onEvent = post
        music.onNotice = { [weak self] notice in self?.notifications.post(notice) }

        timer.onFinish = { [weak self] _ in self?.notifications.playTimerSound() }
        timer.onScheduleChange = { [weak self] endDate in
            self?.notifications.scheduleTimerNotification(at: endDate)
        }

        coordinator.onSwipeOutcome = { [weak self] outcome in
            switch outcome {
            case .nextTrack: self?.music.next()
            case .previousTrack: self?.music.previous()
            default: break
            }
        }

        mediaKeys.volumeHandler = { [weak self] event, fine in
            guard let self, self.volume.canSetVolume else { return false }
            if event.isKeyDown {
                switch event.key {
                case .soundUp: self.volume.step(up: true, fine: fine)
                case .soundDown: self.volume.step(up: false, fine: fine)
                case .mute where !event.isRepeat: self.volume.toggleMute()
                default: break
                }
            }
            return true
        }
        mediaKeys.brightnessHandler = { [weak self] event, fine in
            guard let self, self.brightness.canSetBrightness else { return false }
            if event.isKeyDown {
                return self.brightness.step(up: event.key == .brightnessUp, fine: fine)
            }
            return true
        }
        mediaKeys.brightnessObserved = { [weak self] in
            self?.brightness.brightnessKeyPressed()
        }
        mediaKeys.onStateChange = { [weak self] state in
            self?.mediaKeyState = state
            self?.log.append("keys", "media keys: \(state)")
        }
    }

    /// The event tap is needed for the brightness HUD and for replacing the
    /// system HUD; it can only exist with Accessibility access.
    private func configureMediaKeys() {
        let current = settings.settings
        let wanted = (current.brightness.isEnabled && brightness.isAvailable) || current.mediaKeys.replaceSystemHUD
        mediaKeys.configure(
            wanted: wanted,
            replace: current.mediaKeys.replaceSystemHUD,
            trusted: permissions.isAccessibilityTrusted
        )
        mediaKeyState = mediaKeys.state
    }

    private func handleWake() {
        volume.refresh()
        timer.checkCompletion()
        music.refreshAll()
        mediaKeys.revalidate()
        brightness.refreshAvailability()
        permissions.refreshAll()
        log.append("app", "wake / session active")
    }

    // MARK: - Settings

    private func settingsChanged(_ new: IslandSettings, old: IslandSettings) {
        coordinator.apply(settings: new)
        windowController?.settingsChanged(new, old: old)

        music.apply(settings: new.music)
        volume.apply(settings: new.volume)
        timer.apply(settings: new.timer)
        power.apply(settings: new.power)
        notifications.apply(timerSettings: new.timer)

        // Live activities that were hidden come back with the current state.
        if new.music.showCompact && !old.music.showCompact { music.republish() }
        if new.timer.showCompact && !old.timer.showCompact { timer.publish() }

        if new.mediaKeys.replaceSystemHUD && !old.mediaKeys.replaceSystemHUD && !permissions.isAccessibilityTrusted {
            permissions.requestAccessibility()
        }
        if new.mediaKeys != old.mediaKeys || new.brightness.isEnabled != old.brightness.isEnabled {
            configureMediaKeys()
        }
        if new.general.showMenuBarIcon != old.general.showMenuBarIcon {
            updateStatusItem()
        }
        settingsWindow?.applyTheme(new.appearance.settingsTheme)
    }

    // MARK: - Actions used by views and menus

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(model: self)
        }
        permissions.refreshAll()
        launchAtLogin.refresh()
        settingsWindow?.show()
    }

    func togglePinned() {
        settings.update { $0.general.isPinned.toggle() }
    }

    func toggleEnabled() {
        settings.update { $0.general.isEnabled.toggle() }
    }

    /// Setter for draggable level bars; `nil` when the level cannot be changed.
    func levelSetter(for kind: ActivityKind) -> ((Double) -> Void)? {
        switch kind {
        case .volume where volume.canSetVolume:
            return { [weak self] value in self?.volume.setLevel(value) }
        case .brightness where brightness.canSetBrightness:
            return { [weak self] value in self?.brightness.setLevel(value) }
        default:
            return nil
        }
    }

    func requestAccessibility() {
        permissions.requestAccessibility()
        configureMediaKeys()
    }

    // MARK: - Menus

    private func updateStatusItem() {
        if settings.settings.general.showMenuBarIcon {
            if statusItem == nil {
                statusItem = StatusItemController(menuProvider: { [weak self] in self?.makeContextMenu() ?? NSMenu() })
            }
        } else {
            statusItem?.remove()
            statusItem = nil
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        let general = settings.settings.general

        menu.addItem(MenuAction.item(coordinator.controller.isExpanded ? String(localized: "Collapse Island") : String(localized: "Expand Island")) { [weak self] in
            self?.coordinator.toggleExpanded()
        })
        let pin = MenuAction.item(String(localized: "Keep Expanded")) { [weak self] in self?.togglePinned() }
        pin.state = general.isPinned ? .on : .off
        menu.addItem(pin)
        let enabled = MenuAction.item(String(localized: "Show Island")) { [weak self] in self?.toggleEnabled() }
        enabled.state = general.isEnabled ? .on : .off
        menu.addItem(enabled)

        if settings.settings.timer.isEnabled {
            menu.addItem(.separator())
            let timerMenu = NSMenu()
            for minutes in [1, 5, 10, 25, 60] {
                timerMenu.addItem(MenuAction.item(SettingsFormat.duration(Double(minutes * 60))) { [weak self] in
                    self?.timer.startCountdown(duration: TimeInterval(minutes * 60))
                    self?.coordinator.expand(tab: .timer)
                })
            }
            if timer.countdown.isActive {
                timerMenu.addItem(.separator())
                timerMenu.addItem(MenuAction.item(String(localized: "Cancel Timer")) { [weak self] in self?.timer.resetCountdown() })
            }
            let timerItem = NSMenuItem(title: String(localized: "Start Timer"), action: nil, keyEquivalent: "")
            timerItem.submenu = timerMenu
            menu.addItem(timerItem)
        }

        menu.addItem(.separator())
        menu.addItem(MenuAction.item(String(localized: "Settings…"), key: ",") { [weak self] in self?.showSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(String(localized: "Quit AlcoveInspired"), key: "q") {
            NSApp.terminate(nil)
        })
        return menu
    }
}

/// `NSMenuItem` that runs a closure.
@MainActor
final class MenuAction: NSObject {
    private let handler: () -> Void

    private init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc private func runHandler() {
        handler()
    }

    static func item(_ title: String, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let action = MenuAction(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.runHandler), keyEquivalent: key)
        item.target = action
        // NSMenuItem.target is weak; the represented object keeps the action alive.
        item.representedObject = action
        return item
    }
}
