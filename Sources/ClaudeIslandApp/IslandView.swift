import ClaudeIslandCore
import SwiftUI

/// The island itself: one black shape that morphs between four layouts.
struct IslandView: View {
    @Bindable var model: IslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var shapeNamespace

    private var spring: Animation {
        // Springs only — no duration easing anywhere, so an interrupted morph
        // continues from its current velocity instead of snapping.
        reduceMotion
            ? .spring(response: 0.001, dampingFraction: 1)
            : .spring(response: 0.38, dampingFraction: 0.78)
    }

    var body: some View {
        VStack(spacing: 0) {
            islandShape
            Spacer(minLength: 0)
        }
        .frame(
            width: NotchGeometryResolver.panelWidth,
            height: NotchGeometryResolver.panelHeight,
            alignment: .top
        )
        .animation(spring, value: model.mode)
        .animation(spring, value: model.snapshot.primary?.state)
    }

    private var islandShape: some View {
        ZStack(alignment: .top) {
            // .continuous so the corner curvature interpolates rather than
            // snapping between radii mid-morph.
            RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous)
                // Pure black, no material: it has to read as the physical cutout.
                .fill(Color.black)
                // The shadow lives on the shape leaf, not on the container.
                // Attached to the container, every animating child invalidated
                // it and the recomposite cost measured 4.6% CPU during the
                // alert pulse. Here the pulse composites over a static layer.
                .shadow(
                    color: .black.opacity(model.mode == .dormant ? 0 : 0.35), radius: 12, y: 4
                )
                .overlay(
                    RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous)
                        .strokeBorder(alertStroke, lineWidth: model.mode == .alert ? 1.5 : 0)
                )
                .matchedGeometryEffect(id: "island", in: shapeNamespace, isSource: true)

            content
                .padding(.horizontal, contentPadding)
                .frame(width: model.shapeSize.width, height: model.shapeSize.height)
                .clipped()
        }
        .frame(width: model.shapeSize.width, height: model.shapeSize.height)
        .clipShape(RoundedRectangle(cornerRadius: model.cornerRadius, style: .continuous))
    }

    private var contentPadding: CGFloat {
        switch model.mode {
        case .dormant: 0
        case .compact, .alert: 14
        case .expanded: 16
        }
    }

    private var alertStroke: Color {
        model.mode == .alert ? IslandPalette.alert.opacity(0.9) : .clear
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .dormant:
            Color.clear
        case .compact:
            if let session = model.primary {
                CompactContent(session: session, model: model)
                    .transition(.opacity)
            }
        case .alert:
            if let session = model.primary {
                AlertContent(session: session, model: model)
                    .transition(.opacity)
            }
        case .expanded:
            if let session = model.primary {
                ExpandedContent(session: session, model: model)
                    .transition(.opacity)
            }
        }
    }
}

enum IslandPalette {
    /// Permission requests. Warm enough to read as "you specifically".
    static let alert = Color(red: 1.0, green: 0.58, blue: 0.16)
    static let running = Color(red: 0.42, green: 0.78, blue: 1.0)
    static let thinking = Color(red: 0.62, green: 0.62, blue: 0.68)
    static let error = Color(red: 1.0, green: 0.35, blue: 0.35)
    static let done = Color(red: 0.40, green: 0.85, blue: 0.55)
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.38)

    static func accent(for state: SessionState) -> Color {
        switch state {
        case .awaitingPermission: alert
        case .running: running
        case .error: error
        case .done: done
        case .compacting: Color(red: 0.72, green: 0.55, blue: 1.0)
        case .idle, .prompting, .thinking: thinking
        }
    }
}
