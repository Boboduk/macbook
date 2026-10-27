import AppKit
import IslandCore
import Observation

/// Countdown timer and stopwatch.
///
/// Both are date based (`IslandCore.CountdownTimer` / `Stopwatch`): no
/// ticking while nobody looks, correct after app switches, display sleep and
/// system sleep. The only scheduled work is one wake-up at the countdown's
/// end date. While a countdown runs, App Nap is disabled for the process so
/// the completion is not delayed.
@MainActor
@Observable
final class TimerController {
    enum Mode: String, CaseIterable, Identifiable {
        case countdown
        case stopwatch

        var id: String { rawValue }
    }

    var mode: Mode = .countdown
    private(set) var countdown: CountdownTimer
    private(set) var stopwatch = Stopwatch()

    @ObservationIgnored var onEvent: ((IslandEvent) -> Void)?
    /// Called when a countdown finishes (sound and system notification).
    @ObservationIgnored var onFinish: ((_ duration: TimeInterval) -> Void)?
    /// Called with the end date when a countdown starts or resumes, `nil` when it stops.
    @ObservationIgnored var onScheduleChange: ((Date?) -> Void)?

    @ObservationIgnored private var settings: IslandSettings.Timer
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var appNapActivity: NSObjectProtocol?
    @ObservationIgnored private let defaults: UserDefaults
    private static let storageKey = "timer.state.v1"

    init(settings: IslandSettings.Timer, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        self.countdown = CountdownTimer(duration: settings.defaultDuration)
    }

    var isEnabled: Bool { settings.isEnabled }

    /// Mode shown in the compact island: the countdown wins if both are active.
    var activeMode: Mode? {
        if countdown.isActive { return .countdown }
        if stopwatch.isActive { return .stopwatch }
        return nil
    }

    // MARK: - Lifecycle

    /// Restores a timer that was running when the app quit.
    func restore() {
        guard let data = defaults.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode(SavedState.self, from: data)
        else { return }
        var restoredCountdown = saved.countdown
        if restoredCountdown.completeIfNeeded(at: Date()) {
            // Finished while the app was not running: do not ring late.
            restoredCountdown.reset()
        }
        countdown = restoredCountdown
        stopwatch = saved.stopwatch
        mode = Mode(rawValue: saved.mode) ?? .countdown
        scheduleCompletion()
        publish()
    }

    func apply(settings new: IslandSettings.Timer) {
        let old = settings
        settings = new
        if new.defaultDuration != old.defaultDuration, !countdown.isActive {
            countdown.setDuration(new.defaultDuration)
            persist()
        }
        if !new.isEnabled && old.isEnabled {
            resetCountdown()
            resetStopwatch()
        }
        if new.showCompact != old.showCompact {
            publish()
        }
    }

    /// Checks for a countdown that ended while the Mac was asleep.
    func checkCompletion() {
        if countdown.completeIfNeeded(at: Date()) {
            finish()
        } else {
            scheduleCompletion()
        }
    }

    // MARK: - Countdown

    func setDuration(_ seconds: TimeInterval) {
        guard !countdown.isActive else { return }
        countdown.setDuration(seconds)
        persist()
    }

    func startCountdown() {
        guard settings.isEnabled else { return }
        if countdown.isPaused {
            countdown.resume(at: Date())
        } else {
            countdown.start(at: Date())
        }
        mode = .countdown
        changed()
    }

    func pauseCountdown() {
        countdown.pause(at: Date())
        changed()
    }

    func resetCountdown() {
        countdown.reset()
        changed()
    }

    /// +/- minutes on an active countdown, or a duration change when idle.
    func extendCountdown(by seconds: TimeInterval) {
        countdown.extend(by: seconds, at: Date())
        changed()
    }

    func toggleCountdown() {
        countdown.isRunning ? pauseCountdown() : startCountdown()
    }

    /// Starts a countdown of the given length right away (menu, presets).
    func startCountdown(duration: TimeInterval) {
        countdown.reset()
        countdown.setDuration(duration)
        startCountdown()
    }

    // MARK: - Stopwatch

    func toggleStopwatch() {
        guard settings.isEnabled else { return }
        if stopwatch.isRunning {
            stopwatch.pause(at: Date())
        } else {
            stopwatch.start(at: Date())
            mode = .stopwatch
        }
        changed()
    }

    func lap() {
        stopwatch.lap(at: Date())
        persist()
    }

    func resetStopwatch() {
        stopwatch.reset()
        changed()
    }

    // MARK: - Internals

    private func changed() {
        scheduleCompletion()
        persist()
        publish()
    }

    func publish() {
        let activeMode = self.activeMode
        let isRunning = activeMode == .countdown ? countdown.isRunning : stopwatch.isRunning
        let eventMode: TimerActivityMode? = activeMode.map { $0 == .countdown ? .countdown : .stopwatch }
        onEvent?(.timerActive(eventMode, isRunning: isRunning))
    }

    private func scheduleCompletion() {
        completionTask?.cancel()
        completionTask = nil
        guard let endDate = countdown.endDate else {
            setAppNapDisabled(false)
            onScheduleChange?(nil)
            return
        }
        setAppNapDisabled(true)
        onScheduleChange?(endDate)
        let delay = max(0, endDate.timeIntervalSinceNow)
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            if self.countdown.completeIfNeeded(at: Date()) {
                self.finish()
            } else {
                // Woke slightly early (clock adjustments): try again.
                self.scheduleCompletion()
            }
        }
    }

    private func finish() {
        completionTask = nil
        setAppNapDisabled(false)
        onScheduleChange?(nil)
        let duration = countdown.duration
        persist()
        publish()
        onFinish?(duration)
        onEvent?(.timerFinished(title: "Timer", body: "\(TimeFormatting.shortDuration(duration)) is up"))
    }

    private func setAppNapDisabled(_ disabled: Bool) {
        if disabled, appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Countdown timer running"
            )
        } else if !disabled, let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }
    }

    private struct SavedState: Codable {
        var countdown: CountdownTimer
        var stopwatch: Stopwatch
        var mode: String
    }

    private func persist() {
        let state = SavedState(countdown: countdown, stopwatch: stopwatch, mode: mode.rawValue)
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
