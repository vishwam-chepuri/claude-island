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
        .offset(x: model.shapeOffsetX)
        .animation(spring, value: model.mode)
        .animation(spring, value: model.snapshot.primary?.state)
        // The card's size does not change when the selection does, but the
        // content does; animating on it keeps the swap from snapping.
        .animation(spring, value: model.displaySession?.id)
    }

    private var islandShape: some View {
        ZStack(alignment: .top) {
            // .continuous so the corner curvature interpolates rather than
            // snapping between radii mid-morph.
            IslandShape(cornerRadius: model.cornerRadius, topFlare: model.topFlare)
                // Pure black, no material: it has to read as the physical
                // cutout. The debug tint replaces it with something visible so
                // the shape's edges can actually be seen while iterating.
                .fill(
                    model.debugTint
                        ? AnyShapeStyle(IslandPalette.debugFillGradient)
                        : AnyShapeStyle(IslandPalette.islandFill)
                )
                // The shadow lives on the shape leaf, not on the container.
                // Attached to the container, every animating child invalidated
                // it and the recomposite cost measured 4.6% CPU during the
                // alert pulse. Here the pulse composites over a static layer.
                .shadow(
                    color: .black.opacity(model.mode == .dormant ? 0 : 0.35), radius: 12, y: 4
                )
                // An open path, so no line is ever drawn along the top edge.
                .overlay(
                    IslandOutline(cornerRadius: model.cornerRadius, topFlare: model.topFlare)
                        .stroke(strokeColor, lineWidth: strokeWidth)
                )
                .matchedGeometryEffect(id: "island", in: shapeNamespace, isSource: true)

            // Full shape width, no outer padding. Every tier pads its own
            // content: FlankingRow insets each flank, and the card bodies pad
            // themselves. An outer inset here narrowed the flanking row and
            // shifted its camera gap off the real cutout.
            content
                .frame(width: model.shapeSize.width, height: model.shapeSize.height)
        }
        .frame(width: model.shapeSize.width, height: model.shapeSize.height)
        .clipShape(IslandShape(cornerRadius: model.cornerRadius, topFlare: model.topFlare))
        // contentShape limits the tap target to the drawn shape; without it the
        // gesture would claim the surrounding transparent frame too.
        .contentShape(IslandShape(cornerRadius: model.cornerRadius, topFlare: model.topFlare))
        .onTapGesture {
            guard model.mode != .dormant else { return }
            model.togglePinned()
        }
    }

    private var strokeColor: Color {
        if model.mode == .alert { return IslandPalette.alert.opacity(0.9) }
        return model.debugTint ? IslandPalette.debugStroke : .clear
    }

    private var strokeWidth: CGFloat {
        if model.mode == .alert { return 1.5 }
        return model.debugTint ? 1 : 0
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .dormant:
            Color.clear
        case .compact:
            if let session = model.displaySession {
                CompactContent(session: session, model: model)
                    .transition(.opacity)
            }
        case .alert:
            if let session = model.displaySession {
                AlertContent(session: session, model: model)
                    .transition(.opacity)
            }
        case .peek:
            if let session = model.displaySession {
                PeekContent(session: session, model: model)
                    .transition(.opacity)
            }
        case .expanded:
            if let session = model.displaySession {
                ExpandedContent(session: session, model: model)
                    .transition(.opacity)
            }
        }
    }
}

enum IslandPalette {
    /// Development only. Deep indigo against a cyan edge reads clearly over the
    /// notch, the menu bar and any wallpaper.
    static let debugFill = Color(red: 0.16, green: 0.11, blue: 0.38)
    static let debugStroke = Color(red: 0.45, green: 0.92, blue: 1.0)

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
