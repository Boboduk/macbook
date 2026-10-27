import AppKit
import IslandCore
import Observation
import SwiftUI

/// Now-playing state for Apple Music and Spotify.
///
/// macOS has no public API for "whatever is playing": the private MediaRemote
/// framework is closed to third-party apps since macOS 15.4. Both supported
/// players instead post a public distributed notification on every change
/// (title, artist, album, state — no permission needed) and expose a scripting
/// dictionary for artwork, position and commands (requires the user's
/// Automation consent, asked only when the user first uses a control or taps
/// "Allow").
@MainActor
@Observable
final class MusicController {
    private(set) var snapshot: NowPlayingSnapshot?
    private(set) var artwork: NSImage?
    /// Readable-on-black color derived from the artwork (accent "Artwork").
    private(set) var artworkColor: Color?
    /// Changes with every artwork so views can crossfade.
    private(set) var artworkID = ""
    private(set) var lastErrorMessage: String?

    var track: TrackInfo? { snapshot?.track }
    var isPlaying: Bool { snapshot?.isPlaying ?? false }
    var source: MusicSourceKind? { snapshot?.source }
    var isEnabled: Bool { settings.isEnabled }

    /// Automation status for the active player (or `nil` without a player).
    var automationStatus: AutomationStatus? {
        guard let source else { return nil }
        return permissions.automation[source]
    }

    var canControl: Bool { automationStatus != .denied && snapshot != nil }

    @ObservationIgnored var onEvent: ((IslandEvent) -> Void)?
    @ObservationIgnored var onNotice: ((Notice) -> Void)?

    @ObservationIgnored private let permissions: PermissionService
    @ObservationIgnored private let runner = AppleScriptRunner.shared
    @ObservationIgnored private var settings: IslandSettings.Music
    @ObservationIgnored private var snapshots: [MusicSourceKind: NowPlayingSnapshot] = [:]
    @ObservationIgnored private var updatedAt: [MusicSourceKind: Date] = [:]
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private let artworkCache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var artworkRequestKey: String?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private let artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init(settings: IslandSettings.Music, permissions: PermissionService) {
        self.settings = settings
        self.permissions = permissions
        artworkCache.countLimit = 12
    }

    // MARK: - Lifecycle

    func apply(settings new: IslandSettings.Music) {
        let old = settings
        settings = new
        if new.isEnabled && !isStarted {
            start()
        } else if !new.isEnabled && isStarted {
            stop()
        } else if new.preferredSource != old.preferredSource {
            recompute(announceTrackChange: false)
        } else if new.showCompact != old.showCompact || new.pausedTimeout != old.pausedTimeout {
            republish()
        }
        if new.loadRemoteArtwork != old.loadRemoteArtwork, let snapshot {
            loadArtwork(for: snapshot, force: true)
        }
    }

    func start() {
        guard settings.isEnabled, !isStarted else { return }
        isStarted = true

        let distributed = DistributedNotificationCenter.default()
        for source in MusicSourceKind.allCases {
            let token = distributed.addObserver(
                forName: Notification.Name(source.changeNotificationName),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let info = notification.userInfo ?? [:]
                MainActor.assumeIsolated {
                    self?.handleNotification(info, from: source)
                }
            }
            observers.append((distributed, token))
        }

        let workspace = NSWorkspace.shared.notificationCenter
        let token = workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            MainActor.assumeIsolated {
                self?.applicationTerminated(bundleID)
            }
        }
        observers.append((workspace, token))

        refreshAll()
    }

    func stop() {
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        isStarted = false
        snapshots.removeAll()
        updatedAt.removeAll()
        artworkTask?.cancel()
        snapshot = nil
        artwork = nil
        artworkColor = nil
        onEvent?(.nowPlaying(nil))
    }

    /// Re-reads the state of running players (launch, wake, permission granted).
    func refreshAll() {
        guard isStarted else { return }
        for source in MusicSourceKind.allCases where Self.isRunning(source) {
            permissions.refreshAutomation(for: source) { [weak self] status in
                if status == .granted {
                    self?.queryState(of: source)
                }
            }
        }
    }

    /// Sends the current state again (after settings changed).
    func republish() {
        onEvent?(.nowPlaying(snapshot))
    }

    // MARK: - Position

    func elapsed(at date: Date) -> TimeInterval {
        guard let snapshot, let position = snapshot.position else { return 0 }
        return position.elapsed(at: date, duration: snapshot.track?.duration)
    }

    // MARK: - Commands

    func playPause() {
        guard let source = commandSource() else { return }
        // Optimistic update: the player's notification confirms a moment later.
        if var current = snapshots[source] {
            let now = Date()
            let elapsed = current.position?.elapsed(at: now, duration: current.track?.duration) ?? 0
            current.state = current.isPlaying ? .paused : .playing
            current.position = PlaybackPosition(elapsed: elapsed, timestamp: now, rate: current.isPlaying ? 1 : 0)
            snapshots[source] = current
            recompute(announceTrackChange: false)
        }
        send(MusicScripts.playPause(for: source), to: source)
    }

    func next() {
        guard let source = commandSource() else { return }
        send(MusicScripts.nextTrack(for: source), to: source)
    }

    func previous() {
        guard let source = commandSource() else { return }
        send(MusicScripts.previousTrack(for: source), to: source)
    }

    /// Seeks to a fraction (0...1) of the current track.
    func seek(toFraction fraction: Double) {
        guard let source = commandSource(), var current = snapshots[source],
              let duration = current.track?.duration, duration > 0
        else { return }
        let seconds = min(max(fraction, 0), 1) * duration
        current.position = PlaybackPosition(elapsed: seconds, timestamp: Date(), rate: current.isPlaying ? 1 : 0)
        snapshots[source] = current
        recompute(announceTrackChange: false)
        send(MusicScripts.seek(to: seconds, for: source), to: source, cacheable: false)
    }

    /// Shows the Automation prompt for the active (or running) player.
    func requestAccess() {
        guard let source = snapshot?.source ?? MusicSourceKind.allCases.first(where: { Self.isRunning($0) }) else { return }
        permissions.requestAutomation(for: source) { [weak self] status in
            guard let self else { return }
            if status == .granted {
                self.lastErrorMessage = nil
                self.queryState(of: source)
            } else if status == .denied {
                self.lastErrorMessage = "Access to \(source.displayName) was denied."
            }
        }
    }

    func openAutomationSettings() {
        permissions.open(.automation)
    }

    /// Opens the active player (or Music when nothing plays).
    func openPlayer() {
        let source = snapshot?.source ?? preferredKind ?? .appleMusic
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Updates

    private func handleNotification(_ info: [AnyHashable: Any], from source: MusicSourceKind) {
        let now = Date()
        var parsed = NowPlayingParser.parseNotification(info, source: source, at: now)
        if let track = parsed.track {
            if parsed.position == nil {
                // Music does not include the position: keep extrapolating the
                // previous anchor for the same track, start at 0 for a new one.
                let previous = snapshots[source]
                var elapsed: TimeInterval = 0
                if let previous, let previousTrack = previous.track, Self.isSameTrack(previousTrack, track) {
                    elapsed = previous.position?.elapsed(at: now, duration: track.duration) ?? 0
                }
                parsed.position = PlaybackPosition(elapsed: elapsed, timestamp: now, rate: parsed.isPlaying ? 1 : 0)
            }
            snapshots[source] = parsed
        } else {
            snapshots[source] = nil
        }
        updatedAt[source] = now
        recompute(announceTrackChange: true)

        if parsed.track != nil, source == .appleMusic, permissions.automation[source] == .granted {
            queryState(of: source)
        }
    }

    private func queryState(of source: MusicSourceKind) {
        guard Self.isRunning(source) else { return }
        runner.run(MusicScripts.state(for: source)) { [weak self] result in
            MainActor.assumeIsolated {
                self?.handleStateResult(result, from: source)
            }
        }
    }

    private func handleStateResult(_ result: Result<NSAppleEventDescriptor, AppleScriptRunner.Failure>, from source: MusicSourceKind) {
        switch result {
        case let .success(descriptor):
            guard let parsed = NowPlayingParser.parseScriptFields(descriptor.listValues, source: source, at: Date()) else { return }
            snapshots[source] = parsed.track == nil ? nil : parsed
            if updatedAt[source] == nil { updatedAt[source] = Date() }
            recompute(announceTrackChange: true)
        case let .failure(failure):
            if failure.isPermissionDenied {
                permissions.refreshAutomation(for: source)
            } else if failure.isAppNotRunning {
                snapshots[source] = nil
                recompute(announceTrackChange: false)
            }
        }
    }

    private func applicationTerminated(_ bundleIdentifier: String?) {
        guard let source = MusicSourceKind.allCases.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        guard snapshots[source] != nil else { return }
        snapshots[source] = nil
        recompute(announceTrackChange: false)
    }

    private var preferredKind: MusicSourceKind? {
        switch settings.preferredSource {
        case .automatic: return nil
        case .appleMusic: return .appleMusic
        case .spotify: return .spotify
        }
    }

    /// Preferred player if it has a track; otherwise the most recently updated
    /// playing player; otherwise the most recently updated paused one.
    private func chooseSource() -> MusicSourceKind? {
        let available = snapshots.filter { $0.value.track != nil }
        if let preferred = preferredKind, available[preferred] != nil { return preferred }
        let playing = available.filter { $0.value.isPlaying }
        let pool = playing.isEmpty ? available : playing
        return pool.keys.max { (updatedAt[$0] ?? .distantPast) < (updatedAt[$1] ?? .distantPast) }
    }

    private func recompute(announceTrackChange: Bool) {
        let previousTrack = snapshot?.track
        let newSnapshot = chooseSource().flatMap { snapshots[$0] }
        if newSnapshot != snapshot {
            snapshot = newSnapshot
        }

        if let newSnapshot, let track = newSnapshot.track {
            let isNewTrack = previousTrack.map { !Self.isSameTrack($0, track) } ?? true
            if isNewTrack {
                loadArtwork(for: newSnapshot, force: false)
                if announceTrackChange, previousTrack != nil, newSnapshot.isPlaying {
                    onEvent?(.trackChanged(track, source: newSnapshot.source))
                }
            }
        } else if artwork != nil {
            setArtwork(nil, key: "")
        }
        onEvent?(.nowPlaying(newSnapshot))
    }

    private func commandSource() -> MusicSourceKind? {
        if let source = snapshot?.source, Self.isRunning(source) { return source }
        return MusicSourceKind.allCases.first(where: { Self.isRunning($0) })
    }

    private func send(_ script: String, to source: MusicSourceKind, cacheable: Bool = true) {
        runner.run(script, cacheable: cacheable) { [weak self] result in
            MainActor.assumeIsolated {
                self?.handleCommandResult(result, source: source)
            }
        }
    }

    private func handleCommandResult(_ result: Result<NSAppleEventDescriptor, AppleScriptRunner.Failure>, source: MusicSourceKind) {
        switch result {
        case .success:
            lastErrorMessage = nil
            // The first command may have shown (and passed) the consent prompt.
            if permissions.automation[source] != .granted {
                permissions.refreshAutomation(for: source) { [weak self] status in
                    if status == .granted { self?.queryState(of: source) }
                }
            }
        case let .failure(failure):
            if failure.isPermissionDenied {
                permissions.refreshAutomation(for: source)
                lastErrorMessage = "AlcoveInspired is not allowed to control \(source.displayName)."
                onNotice?(Notice(
                    id: "music.permission",
                    symbol: "lock.fill",
                    title: "Allow control of \(source.displayName)",
                    body: "System Settings › Privacy & Security › Automation",
                    priority: .high
                ))
            } else if !failure.isAppNotRunning {
                lastErrorMessage = failure.message
            }
            // Undo the optimistic update with the real state.
            queryState(of: source)
        }
    }

    // MARK: - Artwork

    private func loadArtwork(for snapshot: NowPlayingSnapshot, force: Bool) {
        guard let track = snapshot.track else { return }
        let key = "\(snapshot.source.rawValue):\(track.id)"
        if !force, key == artworkRequestKey { return }
        artworkRequestKey = key
        artworkTask?.cancel()

        if let cached = artworkCache.object(forKey: key as NSString) {
            setArtwork(cached, key: key)
            return
        }
        guard permissions.automation[snapshot.source] == .granted, Self.isRunning(snapshot.source) else {
            setArtwork(nil, key: key)
            return
        }
        let source = snapshot.source
        runner.run(MusicScripts.artwork(for: source)) { [weak self] result in
            MainActor.assumeIsolated {
                self?.handleArtworkResult(result, key: key, source: source)
            }
        }
    }

    private func handleArtworkResult(_ result: Result<NSAppleEventDescriptor, AppleScriptRunner.Failure>, key: String, source: MusicSourceKind) {
        guard key == artworkRequestKey else { return }
        guard case let .success(descriptor) = result else {
            setArtwork(nil, key: key)
            return
        }
        switch source {
        case .appleMusic:
            let isText = descriptor.descriptorType == AEType.unicodeText || descriptor.descriptorType == AEType.utf8Text
            if !isText, let image = NSImage(data: descriptor.data) {
                artworkCache.setObject(image, forKey: key as NSString)
                setArtwork(image, key: key)
            } else {
                setArtwork(nil, key: key)
            }
        case .spotify:
            guard settings.loadRemoteArtwork,
                  let string = descriptor.stringValue,
                  let url = URL(string: string),
                  url.scheme == "https"
            else {
                setArtwork(nil, key: key)
                return
            }
            downloadArtwork(from: url, key: key)
        }
    }

    /// The only network request of the app: Spotify provides artwork as an
    /// https URL. Can be turned off in Settings › Activities › Music.
    private func downloadArtwork(from url: URL, key: String) {
        let session = artworkSession
        artworkTask = Task { [weak self] in
            let image: NSImage?
            do {
                let (data, response) = try await session.data(from: url)
                let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                image = ok ? NSImage(data: data) : nil
            } catch {
                image = nil
            }
            guard !Task.isCancelled, let self, key == self.artworkRequestKey else { return }
            if let image {
                self.artworkCache.setObject(image, forKey: key as NSString)
            }
            self.setArtwork(image, key: key)
        }
    }

    private func setArtwork(_ image: NSImage?, key: String) {
        let color = image.flatMap { Self.readableColor(from: $0) }
        withAnimation(.smooth(duration: 0.35)) {
            artwork = image
            artworkColor = color
            artworkID = key
        }
    }

    // MARK: - Helpers

    static func isRunning(_ source: MusicSourceKind) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier).isEmpty
    }

    static func isSameTrack(_ lhs: TrackInfo, _ rhs: TrackInfo) -> Bool {
        lhs.id == rhs.id || (lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.album == rhs.album)
    }

    /// Average color of the artwork, lifted so it stays readable on black.
    static func readableColor(from image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var red = 0.0, green = 0.0, blue = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            red += Double(pixels[index])
            green += Double(pixels[index + 1])
            blue += Double(pixels[index + 2])
        }
        let count = Double(side * side) * 255
        let average = NSColor(srgbRed: red / count, green: green / count, blue: blue / count, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(
            hue: Double(hue),
            saturation: Double(min(1, saturation * 1.3)),
            brightness: Double(max(brightness, 0.8))
        )
    }
}
