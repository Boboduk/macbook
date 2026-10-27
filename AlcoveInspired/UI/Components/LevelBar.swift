import SwiftUI

/// Horizontal level indicator. When `onChange` is set it can be dragged; the
/// drag is bracketed with `onEditingChanged` so the island stays open while
/// the user adjusts the value.
struct LevelBar: View {
    var value: Double
    var tint: Color
    var height: CGFloat = 6
    var onChange: ((Double) -> Void)?
    var onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let clamped = min(max(value, 0), 1)
            let barHeight = isDragging ? height + 2 : height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(IslandTheme.trackFill)
                Capsule()
                    .fill(tint)
                    .frame(width: clamped <= 0 ? 0 : max(barHeight, width * clamped))
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width), including: onChange == nil ? .none : .all)
        }
        .animation(.smooth(duration: 0.18), value: value)
        .animation(.smooth(duration: 0.15), value: isDragging)
        .accessibilityElement()
        .accessibilityValue(Text("\(Int((value * 100).rounded())) percent"))
        .accessibilityAdjustableAction { direction in
            guard let onChange else { return }
            switch direction {
            case .increment: onChange(min(1, value + 1.0 / 16))
            case .decrement: onChange(max(0, value - 1.0 / 16))
            @unknown default: break
            }
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if !isDragging {
                    isDragging = true
                    onEditingChanged?(true)
                }
                guard width > 0 else { return }
                onChange?(min(max(gesture.location.x / width, 0), 1))
            }
            .onEnded { _ in
                isDragging = false
                onEditingChanged?(false)
            }
    }
}
