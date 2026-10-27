import IslandCore
import SwiftUI

// MARK: - Compact

struct TimerCompactLeading: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let timer = model.timer
        let accent = IslandTheme.accent(model.coordinator.appearance)
        Group {
            if timer.activeMode == .countdown {
                if let endDate = timer.countdown.endDate {
                    TimelineView(AlignedSecondsSchedule(anchor: endDate)) { context in
                        ProgressRing(progress: timer.countdown.progress(at: context.date), tint: accent, lineWidth: 2.5)
                    }
                } else {
                    ProgressRing(progress: timer.countdown.progress(at: Date()), tint: accent.opacity(0.6), lineWidth: 2.5)
                }
            } else {
                Image(systemName: "stopwatch.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(timer.stopwatch.isRunning ? accent : .white.opacity(0.6))
            }
        }
        .frame(width: 16, height: 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TimerCompactTrailing: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let timer = model.timer
        Group {
            if timer.activeMode == .countdown {
                if let endDate = timer.countdown.endDate {
                    TimelineView(AlignedSecondsSchedule(anchor: endDate)) { context in
                        CompactTime(text: TimeFormatting.clock(timer.countdown.remaining(at: context.date), roundingUp: true), dimmed: false)
                    }
                } else {
                    CompactTime(text: TimeFormatting.clock(timer.countdown.remaining(at: Date()), roundingUp: true), dimmed: true)
                }
            } else if case let .running(since, _) = timer.stopwatch.state {
                TimelineView(AlignedSecondsSchedule(anchor: since)) { context in
                    CompactTime(text: TimeFormatting.clock(timer.stopwatch.elapsed(at: context.date)), dimmed: false)
                }
            } else {
                CompactTime(text: TimeFormatting.clock(timer.stopwatch.elapsed(at: Date())), dimmed: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CompactTime: View {
    let text: String
    let dimmed: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(dimmed ? 0.55 : 1))
            .contentTransition(.numericText(countsDown: true))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

struct ProgressRing: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, 1 - progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.linear(duration: 0.25), value: progress)
    }
}

// MARK: - Expanded page

struct TimerPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var timer = model.timer
        if !timer.isEnabled {
            EmptyStateView(
                symbol: "timer",
                title: "Timer is turned off",
                message: "Turn it on in Settings › Activities.",
                actionTitle: "Open Settings"
            ) { model.showSettings() }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                IslandSegmentedControl(
                    options: TimerController.Mode.allCases,
                    title: { $0 == .countdown ? "Timer" : "Stopwatch" },
                    selection: $timer.mode
                )
                switch timer.mode {
                case .countdown: CountdownPanel()
                case .stopwatch: StopwatchPanel()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CountdownPanel: View {
    @Environment(AppModel.self) private var model
    private let presets: [Int] = [1, 3, 5, 10, 15, 25, 45, 60]

    var body: some View {
        let timer = model.timer
        let countdown = timer.countdown
        let accent = IslandTheme.accent(model.coordinator.appearance)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let endDate = countdown.endDate {
                        TimelineView(AlignedSecondsSchedule(anchor: endDate)) { context in
                            BigTime(text: TimeFormatting.clock(countdown.remaining(at: context.date), roundingUp: true))
                        }
                    } else {
                        BigTime(text: countdown.state == .finished ? "0:00" : TimeFormatting.clock(countdown.remaining(at: Date()), roundingUp: true))
                            .opacity(countdown.isPaused ? 0.6 : 1)
                    }
                }
                Spacer(minLength: 8)
                IslandIconButton(symbol: "arrow.counterclockwise", size: 13, label: "Reset") {
                    timer.resetCountdown()
                }
                .disabled(countdown.state == .idle)
                .opacity(countdown.state == .idle ? 0.35 : 1)
                IslandIconButton(
                    symbol: countdown.isRunning ? "pause.fill" : "play.fill",
                    size: 15,
                    isProminent: true,
                    tint: accent,
                    label: countdown.isRunning ? "Pause" : (countdown.isPaused ? "Resume" : "Start")
                ) {
                    timer.toggleCountdown()
                }
            }

            HStack(spacing: 6) {
                if countdown.isActive {
                    IslandChip(title: "−1 min") { timer.extendCountdown(by: -60) }
                    IslandChip(title: "+1 min") { timer.extendCountdown(by: 60) }
                    IslandChip(title: "+5 min") { timer.extendCountdown(by: 300) }
                    Spacer(minLength: 0)
                    Text(countdown.isPaused ? "Paused" : "Ends \(endTimeText(countdown))")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(IslandTheme.secondaryText(model.coordinator.appearance))
                } else {
                    ForEach(presets, id: \.self) { minutes in
                        IslandChip(title: "\(minutes)m", isSelected: Int(countdown.duration) == minutes * 60) {
                            timer.setDuration(TimeInterval(minutes * 60))
                        }
                    }
                }
            }
        }
    }

    private func endTimeText(_ countdown: CountdownTimer) -> String {
        guard let endDate = countdown.endDate else { return "" }
        return endDate.formatted(date: .omitted, time: .shortened)
    }
}

private struct StopwatchPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let timer = model.timer
        let stopwatch = timer.stopwatch
        let accent = IslandTheme.accent(model.coordinator.appearance)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                // Hundredths animate only while running and visible.
                TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !stopwatch.isRunning)) { context in
                    BigTime(text: TimeFormatting.stopwatch(stopwatch.elapsed(at: context.date)))
                }
                Spacer(minLength: 8)
                IslandIconButton(
                    symbol: stopwatch.isRunning ? "flag.fill" : "arrow.counterclockwise",
                    size: 13,
                    label: stopwatch.isRunning ? "Lap" : "Reset"
                ) {
                    stopwatch.isRunning ? timer.lap() : timer.resetStopwatch()
                }
                .disabled(!stopwatch.isActive)
                .opacity(stopwatch.isActive ? 1 : 0.35)
                IslandIconButton(
                    symbol: stopwatch.isRunning ? "pause.fill" : "play.fill",
                    size: 15,
                    isProminent: true,
                    tint: accent,
                    label: stopwatch.isRunning ? "Pause" : "Start"
                ) {
                    timer.toggleStopwatch()
                }
            }
            HStack(spacing: 10) {
                if stopwatch.laps.isEmpty {
                    Text("Laps appear here")
                        .foregroundStyle(IslandTheme.secondaryText(model.coordinator.appearance))
                } else {
                    ForEach(Array(lapRows(stopwatch).suffix(3)), id: \.number) { lap in
                        Text("Lap \(lap.number)  \(TimeFormatting.stopwatch(lap.split))")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
            }
            .font(.system(size: 10.5, weight: .medium, design: .rounded))
            .monospacedDigit()
            .frame(height: 22)
        }
    }

    private struct LapRow {
        let number: Int
        let split: TimeInterval
    }

    /// Lap durations (time since the previous lap), numbered from 1.
    private func lapRows(_ stopwatch: Stopwatch) -> [LapRow] {
        var previous: TimeInterval = 0
        return stopwatch.laps.enumerated().map { index, total in
            defer { previous = total }
            return LapRow(number: index + 1, split: total - previous)
        }
    }
}

private struct BigTime: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 38, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}
