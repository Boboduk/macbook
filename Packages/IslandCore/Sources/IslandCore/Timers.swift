import Foundation

/// Countdown timer described by dates, not by ticks: it keeps the correct
/// time across app switches, display sleep and system sleep, and it needs no
/// periodic work while nobody is looking at it.
public struct CountdownTimer: Equatable, Codable {
    public enum State: Equatable, Codable {
        case idle
        case running(endDate: Date)
        case paused(remaining: TimeInterval)
        case finished
    }

    public static let minimumDuration: TimeInterval = 1
    public static let maximumDuration: TimeInterval = 24 * 3600

    public private(set) var duration: TimeInterval
    public private(set) var state: State = .idle

    public init(duration: TimeInterval) {
        self.duration = CountdownTimer.clampDuration(duration)
    }

    public static func clampDuration(_ value: TimeInterval) -> TimeInterval {
        min(max(value.rounded(), minimumDuration), maximumDuration)
    }

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    /// Running or paused.
    public var isActive: Bool { isRunning || isPaused }

    public var endDate: Date? {
        if case let .running(endDate) = state { return endDate }
        return nil
    }

    /// Changes the duration. Ignored while the timer is active.
    public mutating func setDuration(_ value: TimeInterval) {
        guard !isActive else { return }
        duration = CountdownTimer.clampDuration(value)
        state = .idle
    }

    public mutating func start(at now: Date) {
        state = .running(endDate: now.addingTimeInterval(duration))
    }

    public mutating func pause(at now: Date) {
        guard case let .running(endDate) = state else { return }
        state = .paused(remaining: max(0, endDate.timeIntervalSince(now)))
    }

    public mutating func resume(at now: Date) {
        guard case let .paused(remaining) = state else { return }
        state = .running(endDate: now.addingTimeInterval(remaining))
    }

    public mutating func reset() {
        state = .idle
    }

    /// Adds (or removes, for negative values) time to an active timer.
    public mutating func extend(by seconds: TimeInterval, at now: Date) {
        switch state {
        case let .running(endDate):
            let newEnd = max(now.addingTimeInterval(1), endDate.addingTimeInterval(seconds))
            state = .running(endDate: newEnd)
        case let .paused(remaining):
            state = .paused(remaining: max(1, remaining + seconds))
        case .idle, .finished:
            setDuration(duration + seconds)
        }
    }

    public func remaining(at now: Date) -> TimeInterval {
        switch state {
        case .idle: return duration
        case let .running(endDate): return max(0, endDate.timeIntervalSince(now))
        case let .paused(remaining): return remaining
        case .finished: return 0
        }
    }

    /// Elapsed fraction, 0...1.
    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(1 - remaining(at: now) / duration, 0), 1)
    }

    /// Moves a running timer whose end date has passed to `.finished`.
    /// Returns `true` exactly once, when the transition happens.
    @discardableResult
    public mutating func completeIfNeeded(at now: Date) -> Bool {
        guard case let .running(endDate) = state, endDate <= now else { return false }
        state = .finished
        return true
    }
}

/// Stopwatch described by dates.
public struct Stopwatch: Equatable, Codable {
    public enum State: Equatable, Codable {
        case idle
        case running(since: Date, accumulated: TimeInterval)
        case paused(accumulated: TimeInterval)
    }

    public private(set) var state: State = .idle
    /// Lap split times (total elapsed at the moment of the lap), oldest first.
    public private(set) var laps: [TimeInterval] = []
    public static let maximumLaps = 99

    public init() {}

    public var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    public var isActive: Bool { state != .idle }

    public func elapsed(at now: Date) -> TimeInterval {
        switch state {
        case .idle: return 0
        case let .running(since, accumulated): return accumulated + max(0, now.timeIntervalSince(since))
        case let .paused(accumulated): return accumulated
        }
    }

    public mutating func start(at now: Date) {
        switch state {
        case .idle: state = .running(since: now, accumulated: 0)
        case let .paused(accumulated): state = .running(since: now, accumulated: accumulated)
        case .running: break
        }
    }

    public mutating func pause(at now: Date) {
        guard isRunning else { return }
        state = .paused(accumulated: elapsed(at: now))
    }

    public mutating func lap(at now: Date) {
        guard isRunning else { return }
        laps.append(elapsed(at: now))
        if laps.count > Stopwatch.maximumLaps { laps.removeFirst(laps.count - Stopwatch.maximumLaps) }
    }

    public mutating func reset() {
        state = .idle
        laps = []
    }
}

public enum TimeFormatting {
    /// `m:ss` or `h:mm:ss`. Countdowns round up so the display reaches 0:00
    /// exactly when the timer ends.
    public static func clock(_ interval: TimeInterval, roundingUp: Bool = false) -> String {
        guard interval.isFinite else { return "--:--" }
        let raw = max(0, interval)
        let total = Int(roundingUp ? raw.rounded(.up) : raw.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// `mm:ss.cc` (or `h:mm:ss.cc`) for the stopwatch.
    public static func stopwatch(_ interval: TimeInterval, showHundredths: Bool = true) -> String {
        let raw = max(0, interval)
        let totalHundredths = Int((raw * 100).rounded(.down))
        let hundredths = totalHundredths % 100
        let totalSeconds = totalHundredths / 100
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        var result = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
        if showHundredths { result += String(format: ".%02d", hundredths) }
        return result
    }

    /// Short human description of a duration: "5 min", "1 h 30 min", "45 s".
    public static func shortDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours) h \(minutes) min" : "\(hours) h" }
        if minutes > 0 { return seconds > 0 ? "\(minutes) min \(seconds) s" : "\(minutes) min" }
        return "\(seconds) s"
    }
}
