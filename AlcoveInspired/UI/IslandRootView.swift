import IslandCore
import SwiftUI

/// Root of the island panel. The panel never changes size; this view fills it
/// and draws the island top-centered. Only the island's frame, corner radii
/// and content animate.
struct IslandRootView: View {
    let model: AppModel

    var body: some View {
        IslandCanvas(coordinator: model.coordinator)
            .environment(model)
            .ignoresSafeArea()
    }
}

private struct IslandCanvas: View {
    let coordinator: IslandCoordinator

    var body: some View {
        let panel = coordinator.panelSize
        ZStack(alignment: .top) {
            IslandBody(coordinator: coordinator)
        }
        .frame(width: panel.width, height: panel.height, alignment: .top)
    }
}

private struct IslandBody: View {
    let coordinator: IslandCoordinator

    var body: some View {
        let frame = coordinator.islandFrame
        let presentation = coordinator.presentation
        let shape = IslandShape(topRadius: frame.topRadius, bottomRadius: frame.bottomRadius)

        IslandContentView(presentation: presentation)
            .frame(width: frame.size.width, height: frame.size.height, alignment: .top)
            .clipShape(shape)
            .background {
                shape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(shadowOpacity(for: presentation)), radius: 18, x: 0, y: 8)
            }
            .contentShape(shape)
            .onTapGesture { coordinator.tap() }
            .opacity(frame.isVisible ? 1 : 0)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Island"))
            .accessibilityAddTraits(.isButton)
    }

    private func shadowOpacity(for presentation: IslandPresentation) -> Double {
        guard coordinator.appearance.showShadow else { return 0 }
        switch presentation {
        case .hidden, .idle: return 0
        case .compact: return 0.25
        case .banner, .expanded: return 0.5
        }
    }
}

/// Picks the content for the presentation. Changing `contentKey` swaps the
/// content with a blur/fade transition inside the same spring that resizes
/// the shape; updates with the same key happen in place.
struct IslandContentView: View {
    let presentation: IslandPresentation
    @Environment(AppModel.self) private var model

    var body: some View {
        let size = model.coordinator.contentSize(for: presentation.shapeKind)
        ZStack(alignment: .top) {
            content
                .frame(width: size.width, height: size.height, alignment: .top)
                .id(presentation.contentKey)
                .transition(.islandContent)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .hidden, .idle:
            Color.clear
        case let .compact(activity, _):
            CompactIslandView(activity: activity)
        case let .banner(activity, _):
            BannerIslandView(activity: activity)
        case let .expanded(context):
            ExpandedIslandView(context: context)
        }
    }
}
