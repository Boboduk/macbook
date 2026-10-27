import AppKit
import SwiftUI

/// Animated "now playing" bars.
///
/// Implemented with Core Animation: each bar runs an infinite
/// `CABasicAnimation` that is evaluated by the render server, so the app's
/// CPU stays idle while music plays. The bars are a playback indicator, not a
/// spectrum analyzer (capturing system audio would need extra permissions).
struct PlaybackIndicatorView: View {
    var barCount: Int = 4
    @Environment(AppModel.self) private var model

    var body: some View {
        let appearance = model.coordinator.appearance
        let color = IslandTheme.accent(appearance, artworkColor: model.music.artworkColor)
        PlaybackBars(isAnimating: model.music.isPlaying, color: NSColor(color), barCount: barCount)
            .accessibilityHidden(true)
    }
}

private struct PlaybackBars: NSViewRepresentable {
    var isAnimating: Bool
    var color: NSColor
    var barCount: Int

    func makeNSView(context: Context) -> PlaybackBarsView {
        PlaybackBarsView(barCount: barCount)
    }

    func updateNSView(_ view: PlaybackBarsView, context: Context) {
        view.update(color: color, animating: isAnimating)
    }
}

final class PlaybackBarsView: NSView {
    private var bars: [CALayer] = []
    private var isAnimating = false
    private static let animationKey = "playback.pulse"
    /// Different periods so the bars never move in lockstep.
    private static let durations: [CFTimeInterval] = [0.42, 0.55, 0.37, 0.61, 0.48]
    private static let restingScale: CGFloat = 0.35

    init(barCount: Int) {
        super.init(frame: .zero)
        // Layer-hosting view: the bars are plain sublayers.
        layer = CALayer()
        wantsLayer = true
        layer?.masksToBounds = false
        for _ in 0..<max(1, barCount) {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            bar.transform = CATransform3DMakeScale(1, Self.restingScale, 1)
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let count = CGFloat(bars.count)
        let gap = max(1.5, bounds.width / (count * 3))
        let width = max(1.5, (bounds.width - gap * (count - 1)) / count)
        for (index, bar) in bars.enumerated() {
            let x = CGFloat(index) * (width + gap)
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: x + width / 2, y: bounds.midY)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }

    func update(color: NSColor, animating: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            bar.backgroundColor = color.cgColor
        }
        CATransaction.commit()

        let shouldAnimate = animating && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard shouldAnimate != isAnimating else { return }
        isAnimating = shouldAnimate
        shouldAnimate ? startAnimating() : stopAnimating()
    }

    private func startAnimating() {
        let now = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.25
            animation.toValue = 1.0
            animation.duration = Self.durations[index % Self.durations.count]
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = now + Double(index) * 0.11
            animation.fillMode = .backwards
            bar.add(animation, forKey: Self.animationKey)
        }
    }

    private func stopAnimating() {
        for bar in bars {
            bar.removeAnimation(forKey: Self.animationKey)
            bar.transform = CATransform3DMakeScale(1, Self.restingScale, 1)
        }
    }
}

/// Album artwork with a neutral placeholder; crossfades on track change and
/// shrinks slightly while paused.
struct ArtworkView: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let music = model.music
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [Color(white: 0.24), Color(white: 0.12)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.5))
            if let image = music.artwork {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .id(music.artworkID)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .scaleEffect(music.isPlaying ? 1 : 0.9)
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: music.isPlaying)
        .accessibilityLabel(Text("Album artwork"))
    }
}
