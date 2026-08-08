import ClaudeIslandCore
import SwiftUI

// The island's visual language.
//
// Every state owns a two-stop accent rather than a flat colour, so a glyph, a
// ring and a bar can all be tinted from one source and still read as lit rather
// than filled. The fill itself stays essentially black: it has to keep passing
// for the camera housing, so the gradient on it is a few points of lift at the
// top and nothing more.

struct Accent {
    let base: Color
    let bright: Color

    var gradient: LinearGradient {
        LinearGradient(
            colors: [bright, base], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// For rings and arcs, where a sweep reads better than a diagonal.
    var sweep: AngularGradient {
        AngularGradient(
            colors: [base, bright, base], center: .center, startAngle: .degrees(-90),
            endAngle: .degrees(270))
    }

    var glow: Color { bright.opacity(0.35) }
    var wash: Color { base.opacity(0.16) }
}

extension IslandPalette {
    static let workingAccent = Accent(
        base: Color(red: 0.18, green: 0.48, blue: 1.00),
        bright: Color(red: 0.37, green: 0.78, blue: 1.00))
    static let thinkingAccent = Accent(
        base: Color(red: 0.49, green: 0.42, blue: 1.00),
        bright: Color(red: 0.70, green: 0.62, blue: 1.00))
    static let turnAccent = Accent(
        base: Color(red: 1.00, green: 0.54, blue: 0.12),
        bright: Color(red: 1.00, green: 0.77, blue: 0.42))
    static let doneAccent = Accent(
        base: Color(red: 0.13, green: 0.78, blue: 0.49),
        bright: Color(red: 0.48, green: 0.94, blue: 0.72))
    static let errorAccent = Accent(
        base: Color(red: 1.00, green: 0.30, blue: 0.37),
        bright: Color(red: 1.00, green: 0.60, blue: 0.65))
    static let compactingAccent = Accent(
        base: Color(red: 0.66, green: 0.33, blue: 0.97),
        bright: Color(red: 0.85, green: 0.71, blue: 1.00))
    static let idleAccent = Accent(
        base: Color(red: 0.42, green: 0.45, blue: 0.50),
        bright: Color(red: 0.61, green: 0.64, blue: 0.69))

    static func accentPair(for state: SessionState) -> Accent {
        switch state {
        case .running: workingAccent
        case .thinking, .prompting: thinkingAccent
        case .awaitingPermission: turnAccent
        case .idle(let waiting): waiting ? turnAccent : idleAccent
        case .compacting: compactingAccent
        case .done: doneAccent
        case .error: errorAccent
        }
    }

    /// The island's own fill. A few points of lift at the top gives the shape
    /// some form under a bright wallpaper without breaking the illusion that it
    /// is the cutout.
    static var islandFill: LinearGradient {
        LinearGradient(
            colors: [Color(white: 0.055), .black],
            startPoint: .top, endPoint: .bottom)
    }

    static var debugFillGradient: LinearGradient {
        LinearGradient(colors: [debugFill.opacity(0.95), debugFill], startPoint: .top, endPoint: .bottom)
    }

    /// Context occupancy, coloured by how much room is left. Green while there
    /// is plenty, amber past two thirds, red when a compaction is imminent.
    static func contextAccent(_ fraction: Double) -> Accent {
        switch fraction {
        case ..<0.66: doneAccent
        case ..<0.85: turnAccent
        default: errorAccent
        }
    }
}

// MARK: - Components

/// A thin arc showing context occupancy, wrapped around whatever it encloses.
struct ContextRing<Content: View>: View {
    let fraction: Double
    let accent: Accent
    @ViewBuilder var content: Content

    var body: some View {
        content
            .overlay {
                if fraction > 0.001 {
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            accent.sweep,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .padding(-3)
                }
            }
    }
}

/// A labelled figure with a tinted plate behind it.
///
/// The plate is what separates one stat from the next at a glance; bare numbers
/// in a row read as a sentence and have to be parsed.
struct StatChip: View {
    let label: String
    let value: String
    var accent: Accent = IslandPalette.idleAccent
    var emphasised = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: emphasised ? 14 : 12, weight: .semibold, design: .rounded))
                .foregroundStyle(emphasised ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(.white))
                .monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 7.5, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(IslandPalette.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minWidth: 58, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(emphasised ? accent.wash : Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    emphasised ? accent.base.opacity(0.35) : Color.white.opacity(0.06),
                    lineWidth: 1)
        )
    }
}

/// The cache hit ratio, on screen only while it is worth reading — see
/// `TokenStats.degradedCacheHitRatio` for when that is.
///
/// Amber, not green: by the time this appears it is an explanation for a turn
/// that ran slow and expensive, not a badge for one that went well.
struct CacheChip: View {
    let tokens: TokenStats

    var body: some View {
        if let ratio = tokens.degradedCacheHitRatio {
            StatChip(
                label: "cache hit", value: Format.percent(ratio),
                accent: IslandPalette.turnAccent)
        }
    }
}

/// A slim capsule bar. Used for context occupancy and plan progress.
struct MeterBar: View {
    let fraction: Double
    let accent: Accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                // Nothing at all at zero: a minimum-width cap left a stray dot
                // that read as a tiny amount of usage rather than none.
                if fraction > 0.001 {
                    Capsule()
                        .fill(accent.gradient)
                        .frame(
                            width: max(height, geo.size.width * min(1, fraction)))
                        .shadow(color: accent.glow, radius: 3)
                }
            }
        }
        .frame(height: height)
    }
}

/// Plan progress as filled and unfilled segments — countable at a glance in a
/// way a fraction is not.
struct TaskSegments: View {
    let completed: Int
    let total: Int
    let accent: Accent

    private var shown: Int { min(total, 12) }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<max(shown, 0), id: \.self) { index in
                Capsule()
                    .fill(
                        index < completed
                            ? AnyShapeStyle(accent.gradient)
                            : AnyShapeStyle(Color.white.opacity(0.12))
                    )
                    .frame(height: 4)
            }
            if total > shown {
                Text("+\(total - shown)")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(IslandPalette.tertiary)
            }
        }
    }
}
