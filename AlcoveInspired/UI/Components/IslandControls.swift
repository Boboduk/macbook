import SwiftUI

/// Progress bar that can be scrubbed; the value is committed once, when the
/// drag ends (one seek command instead of dozens).
struct ScrubBar: View {
    var progress: Double
    var tint: Color
    var isEnabled: Bool
    var onCommit: (Double) -> Void
    var onEditingChanged: ((Bool) -> Void)?

    @State private var dragProgress: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let shown = min(max(dragProgress ?? progress, 0), 1)
            let height: CGFloat = dragProgress == nil ? 4 : 6
            ZStack(alignment: .leading) {
                Capsule().fill(IslandTheme.trackFill)
                Capsule()
                    .fill(tint)
                    .frame(width: shown <= 0 ? 0 : max(height, width * shown))
            }
            .frame(height: height)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragProgress == nil { onEditingChanged?(true) }
                        dragProgress = min(max(gesture.location.x / width, 0), 1)
                    }
                    .onEnded { gesture in
                        let value = min(max(gesture.location.x / width, 0), 1)
                        dragProgress = nil
                        onEditingChanged?(false)
                        onCommit(value)
                    },
                including: isEnabled ? .all : .none
            )
        }
        .animation(.smooth(duration: 0.15), value: dragProgress == nil)
    }
}

/// Round icon button used for transport and timer controls.
struct IslandIconButton: View {
    let symbol: String
    var size: CGFloat = 15
    var isProminent = false
    var tint: Color = .white
    var label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isProminent ? Color.black : tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 2.2, height: size * 2.2)
                .background(
                    Circle().fill(isProminent ? tint : Color.white.opacity(isHovering ? 0.14 : 0))
                )
                .scaleEffect(isHovering ? 1.06 : 1)
        }
        .buttonStyle(IslandPressStyle())
        .onHover { isHovering = $0 }
        .animation(.smooth(duration: 0.15), value: isHovering)
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

/// Shrinks a little while pressed.
struct IslandPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// Dark capsule segmented control that fits the island.
struct IslandSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let title: (Value) -> String
    @Binding var selection: Value
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(title(option))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.75))
                        .padding(.horizontal, 10)
                        .frame(height: 20)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.white)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }
}

/// Small capsule chip (timer presets, +/- minute).
struct IslandChip: View {
    let title: String
    var isSelected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.black : Color.white.opacity(0.85))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(Capsule().fill(isSelected ? Color.white : Color.white.opacity(0.1)))
        }
        .buttonStyle(IslandPressStyle())
    }
}

/// Timeline schedule that fires at whole seconds relative to `anchor`
/// (the countdown's end date or the stopwatch's start), so the displayed
/// seconds change exactly on time with one update per second.
struct AlignedSecondsSchedule: TimelineSchedule {
    let anchor: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        var fraction = anchor.timeIntervalSince(startDate).truncatingRemainder(dividingBy: 1)
        if fraction <= 0 { fraction += 1 }
        // A small offset past each boundary avoids rounding to the old second.
        return Entries(first: startDate, upcoming: startDate.addingTimeInterval(fraction + 0.02))
    }

    struct Entries: Sequence, IteratorProtocol {
        var first: Date?
        var upcoming: Date

        mutating func next() -> Date? {
            if let first {
                self.first = nil
                return first
            }
            defer { upcoming = upcoming.addingTimeInterval(1) }
            return upcoming
        }
    }
}
