#!/usr/bin/env swift
//
// Draws ClaudeIsland.app's icon and writes Resources/AppIcon.icns.
//
// The icon is generated rather than drawn by hand for the same reason the app
// has no image assets: every shape in it already exists in the source. The pill
// is cut from `IslandCorner`'s superellipse profile, the figure lit inside it is
// `StatusMark`'s `running` pose — three balls on a ground line — and the blue is
// `IslandPalette.workingAccent`. If the island's corners or its accent ever
// change, this redraws to match instead of drifting away from them.
//
// The one shape that is not the app's own is the outer plate, which belongs to
// whatever macOS is showing it. See `Layout.plate`.
//
// Not wired into bundle.sh: the .icns is committed, so an install builds no
// pictures. Run this only after changing the design.
//
//   swift Scripts/make-icon.swift                        # → Resources/AppIcon.icns
//   swift Scripts/make-icon.swift --png x.png [--size n] # one rendition, to look at
//
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - The island's corner profile
//
// Ported from Sources/ClaudeIslandApp/IslandShape.swift, in a y-down space.
// A superellipse quadrant, not a circular arc: curvature ramps up from zero at
// the joins, which is the difference between a corner that reads as machined
// and one that reads as drawn.

enum IslandCorner {
    static let exponent: CGFloat = 4
    static let spanRatio: CGFloat = 1.528
    static let segments = 20
    static func span(_ radius: CGFloat) -> CGFloat { max(0, radius) * spanRatio }
}

extension CGMutablePath {
    /// Turns the corner at `corner`, arriving along `from` and leaving along
    /// `to` — both unit vectors pointing away from the corner, down the edges
    /// that meet there. The curve runs `span` along each.
    func addSmoothCorner(at corner: CGPoint, from: CGVector, to: CGVector, span: CGFloat) {
        guard span > 0 else {
            addLine(to: corner)
            return
        }
        let e = 2 / IslandCorner.exponent
        for step in 1...IslandCorner.segments {
            let t = CGFloat(step) / CGFloat(IslandCorner.segments) * (.pi / 2)
            let along = span * (1 - pow(cos(t), e))
            let away = span * (1 - pow(sin(t), e))
            addLine(
                to: CGPoint(
                    x: corner.x + to.dx * along + from.dx * away,
                    y: corner.y + to.dy * along + from.dy * away))
        }
    }
}

/// A rectangle with all four corners cut from the island's profile — the shape
/// the app draws on a display with no notch to grow out of.
func islandPath(in rect: CGRect, radius: CGFloat) -> CGPath {
    let wanted = IslandCorner.span(radius)
    let span = min(wanted, rect.width / 2, rect.height / 2)
    let path = CGMutablePath()

    path.move(to: CGPoint(x: rect.minX, y: rect.minY + span))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - span))
    path.addSmoothCorner(
        at: CGPoint(x: rect.minX, y: rect.maxY),
        from: CGVector(dx: 0, dy: -1), to: CGVector(dx: 1, dy: 0), span: span)
    path.addLine(to: CGPoint(x: rect.maxX - span, y: rect.maxY))
    path.addSmoothCorner(
        at: CGPoint(x: rect.maxX, y: rect.maxY),
        from: CGVector(dx: -1, dy: 0), to: CGVector(dx: 0, dy: -1), span: span)
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + span))
    path.addSmoothCorner(
        at: CGPoint(x: rect.maxX, y: rect.minY),
        from: CGVector(dx: 0, dy: 1), to: CGVector(dx: -1, dy: 0), span: span)
    path.addLine(to: CGPoint(x: rect.minX + span, y: rect.minY))
    path.addSmoothCorner(
        at: CGPoint(x: rect.minX, y: rect.minY),
        from: CGVector(dx: 1, dy: 0), to: CGVector(dx: 0, dy: 1), span: span)
    path.closeSubpath()
    return path
}

// MARK: - Palette

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

enum Palette {
    /// IslandPalette.workingAccent, unchanged. Blue is what the island is doing
    /// most of the time you look at it.
    static let accentBase = rgba(0.18, 0.48, 1.00)
    static let accentBright = rgba(0.37, 0.78, 1.00)

    /// The island's own fill: pitch black, because on screen it has to be the
    /// same nothing as the camera cutout.
    static let islandFill = rgba(0, 0, 0)

    /// The plate behind it. Graphite, barely blued — bezel, not brand. A navy
    /// plate was the other candidate and it read as a second colour competing
    /// with the accent; keeping the plate neutral leaves blue as the only hue
    /// in the icon, which is what has to survive being 32 points wide.
    ///
    /// Light enough, too, that a pitch-black pill reads as an object sitting on
    /// it rather than a hole punched through it. The first pass was two stops
    /// darker and the pill all but vanished at Finder sizes.
    static let plateTop = rgba(0.30, 0.325, 0.375)
    static let plateBottom = rgba(0.095, 0.105, 0.130)
}

// MARK: - Layout
//
// Everything is expressed against a 1024 canvas and scaled to whatever size is
// being rendered, so the smallest icon is the same drawing rather than a
// different one.

enum Layout {
    static let canvas: CGFloat = 1024

    /// The plate runs to all four edges, which is not how a pre-Tahoe icon is
    /// drawn and is nevertheless right.
    ///
    /// macOS 26 does not show a legacy .icns as authored: it scales the whole
    /// canvas down onto its own glass plate and masks it to the system
    /// squircle. Artwork that draws its own inset shape — the stock 0.797 body
    /// with a shadow around it — comes back as a small dark tile floating on a
    /// white plate, framed twice. Filling the canvas is what makes the mask
    /// land on the artwork instead of around it, and the result is
    /// indistinguishable from a native icon. Checked by asking NSWorkspace what
    /// it resolves for a built bundle, not by assuming.
    static let plate = CGRect(x: 0, y: 0, width: 1024, height: 1024)

    /// Rounding macOS 26 never sees — its mask cuts far deeper than this — kept
    /// for macOS 14 and 15, which show the artwork exactly as drawn and would
    /// otherwise get a hard-cornered square. 190 is comfortably inside the
    /// mask: the corner would have to reach past about 226 before the system
    /// plate started showing through behind it.
    static let plateRadius: CGFloat = 190

    static let pill = CGRect(x: 122, y: 370, width: 780, height: 284)
    /// Past what the shape can take at this height, so both ends round fully —
    /// which is what the real pill does too, its 12pt corners being wider than
    /// its 32pt body is tall.
    static let pillRadius: CGFloat = 200

    /// The 16pt slot StatusMark reserves, blown up — and blown up further
    /// across than down. The figure is nearly square in the slot, and a square
    /// of anything centred in a pill leaves two dead ends; widening only the
    /// spacing keeps the balls their own size while the group spans the shape
    /// it lives in. The stage stretches, the actors do not.
    static let markScale: CGFloat = 26.4
    static let markSpread: CGFloat = 39
    static let markCentre = CGPoint(x: pill.midX, y: pill.midY)
}

// MARK: - The running figure
//
// StatusMark's `bounce`, frozen. Sizes, positions, floor and squash are that
// file's numbers, mismatched ball sizes included — on screen the mismatch is
// what keeps three balls from moving as a chorus line. Only the heights are
// chosen here, because on screen they are the animation and a still has to
// pick one frame of it.

enum Mark {
    static let slot: CGFloat = 16
    static let sizes: [CGFloat] = [3.4, 3.8, 3.2]
    static let xs: [CGFloat] = [4.2, 8.0, 11.8]
    static let floor: CGFloat = 3
    /// Where each ball is caught. Climbing left to right, off a squash on the
    /// floor, so the three read as one ball's arc rather than three unrelated
    /// dots — a still cannot borrow the motion the app has, and has to compose
    /// the motion instead. The app's own scatter was tried first and read as a
    /// face. Level dots were never an option: that is `thinking`.
    static let bottoms: [CGFloat] = [3.0, 5.2, 7.6]
    static let squashY: CGFloat = 0.62
    static let squashX: CGFloat = 1.24

    /// How far the ground runs past the outermost ball, in slot units — the
    /// app's 13-unit line, restated as the overhang it actually is.
    static let groundOverhang: CGFloat = 1.0
    static let groundThickness: CGFloat = 0.9
    /// Louder than the app's 0.28. On screen the ground only has to hint that
    /// the balls share a floor; at icon sizes it is also the horizontal line
    /// holding the composition together, and 0.28 of anything vanishes by 32pt.
    static let groundAlpha: CGFloat = 0.36

    /// What the figure occupies, bottom of the ground to top of the highest
    /// ball. The drawing centres this, not the slot — the slot has headroom for
    /// an event swell that a still frame never uses.
    static let base: CGFloat = floor - groundThickness
    static var apex: CGFloat {
        zip(bottoms, sizes).map { $0 + $1 }.max() ?? floor
    }
}

// MARK: - Drawing

/// Slot coordinates (y up, origin at the slot's bottom-left) to canvas
/// coordinates (y down).
func slotPoint(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    let baseline = Layout.markCentre.y + (Mark.apex - Mark.base) * Layout.markScale / 2
    return CGPoint(
        x: Layout.markCentre.x + (x - Mark.slot / 2) * Layout.markSpread,
        y: baseline - (y - Mark.base) * Layout.markScale)
}

func drawIcon(in ctx: CGContext, size: CGFloat) {
    // A y-down space the whole file can share, so the ported path code reads
    // the same as the SwiftUI it came from.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: size / Layout.canvas, y: -size / Layout.canvas)

    let plate = CGPath(
        roundedRect: Layout.plate, cornerWidth: Layout.plateRadius,
        cornerHeight: Layout.plateRadius, transform: nil)

    // No drop shadow under the plate. The stock icons bake one into their
    // margin; this one has no margin to bake it into, and macOS 26 lights the
    // icon itself.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()

    let gradient = CGGradient(
        colorsSpace: sRGB, colors: [Palette.plateTop, Palette.plateBottom] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: Layout.plate.minY),
        end: CGPoint(x: 0, y: Layout.plate.maxY), options: [])

    // What the pill is throwing off. Without it the black shape is pasted on;
    // with it the plate looks lit from inside by whatever the island is doing.
    let bloom = CGGradient(
        colorsSpace: sRGB,
        colors: [
            rgba(0.18, 0.48, 1.00, 0.30), rgba(0.18, 0.48, 1.00, 0.10),
            rgba(0.18, 0.48, 1.00, 0),
        ] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawRadialGradient(
        bloom, startCenter: Layout.markCentre, startRadius: 0,
        endCenter: Layout.markCentre, endRadius: 540, options: [])

    // A hairline of light along the top edge, the way a glass plate catches it.
    ctx.saveGState()
    ctx.addPath(plate)
    ctx.clip()
    let sheen = CGGradient(
        colorsSpace: sRGB,
        colors: [rgba(1, 1, 1, 0.13), rgba(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        sheen, start: CGPoint(x: 0, y: Layout.plate.minY),
        end: CGPoint(x: 0, y: Layout.plate.minY + 200), options: [])
    ctx.restoreGState()

    // The island.
    let pill = islandPath(in: Layout.pill, radius: Layout.pillRadius)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 12), blur: 40, color: rgba(0, 0, 0, 0.55))
    ctx.addPath(pill)
    ctx.setFillColor(Palette.islandFill)
    ctx.fillPath()
    ctx.restoreGState()

    // The rim is what keeps a pitch-black shape on a dark plate from reading as
    // a hole punched through it.
    ctx.saveGState()
    ctx.addPath(pill)
    ctx.setLineWidth(3)
    ctx.setStrokeColor(rgba(1, 1, 1, 0.09))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(pill)
    ctx.clip()
    drawMark(in: ctx, size: size)
    ctx.restoreGState()

    ctx.restoreGState()
}

/// Where the three balls land on the canvas. A ball at the floor is squashed —
/// wider and flatter — which is the one thing in the whole set that changes
/// shape, and the reason `running` reads as bouncing rather than blinking.
func ballRects() -> [CGRect] {
    (0..<Mark.sizes.count).map { index in
        let landed = Mark.bottoms[index] <= Mark.floor + 0.001
        let width = Mark.sizes[index] * (landed ? Mark.squashX : 1) * Layout.markScale
        let height = Mark.sizes[index] * (landed ? Mark.squashY : 1) * Layout.markScale
        let bottom = slotPoint(Mark.xs[index], Mark.bottoms[index])
        // A landed ball is sunk a little into the ground rather than set on top
        // of it. Two edges meeting exactly leave an antialiased hairline of
        // background between them, which at icon sizes reads as a ball
        // hovering — the opposite of the contact the squash is there to sell.
        let sink = landed ? Mark.groundThickness * Layout.markScale * 0.55 : 0
        return CGRect(
            x: bottom.x - width / 2, y: bottom.y - height + sink, width: width, height: height)
    }
}

func drawMark(in ctx: CGContext, size: CGFloat) {
    let k = Layout.markScale
    let rects = ballRects()
    let bounds = rects.reduce(CGRect.null) { $0.union($1) }

    // The ground the balls are bouncing off. Quiet: it is the stage, not the
    // act. Floored at half a device pixel so it survives the 16pt render.
    //
    // The app's ground is 13 units of 16: not a measurement so much as "a
    // little past the balls at either end". Stretching the slot across would
    // turn that overhang into two long tails, so it is rebuilt from where the
    // balls actually landed instead.
    let overhang = Mark.groundOverhang * k
    let thickness = max(Mark.groundThickness * k, Layout.canvas / size * 0.5)
    let ground = CGRect(
        x: bounds.minX - overhang, y: slotPoint(0, Mark.floor).y,
        width: bounds.width + overhang * 2, height: thickness)
    ctx.addPath(
        CGPath(
            roundedRect: ground, cornerWidth: thickness / 2, cornerHeight: thickness / 2,
            transform: nil))
    ctx.setFillColor(
        Palette.accentBase.copy(alpha: Mark.groundAlpha) ?? Palette.accentBase)
    ctx.fillPath()

    // One path for all three so a single gradient runs across the group — the
    // same reason Accent.gradient is one fill and not three.
    let balls = CGMutablePath()
    for rect in rects {
        balls.addPath(
            CGPath(
                roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2,
                transform: nil))
    }

    ctx.saveGState()
    ctx.setShadow(
        offset: .zero, blur: 26, color: rgba(0.37, 0.78, 1.00, 0.55))
    ctx.addPath(balls)
    ctx.setFillColor(Palette.accentBright)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(balls)
    ctx.clip()
    let lit = CGGradient(
        colorsSpace: sRGB, colors: [Palette.accentBright, Palette.accentBase] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        lit, start: CGPoint(x: bounds.minX, y: bounds.minY),
        end: CGPoint(x: bounds.maxX, y: bounds.maxY), options: [])
    ctx.restoreGState()
}

// MARK: - Output

func render(size: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawIcon(in: ctx, size: CGFloat(size))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw Failure("cannot encode \(url.path)")
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The ten renditions .icns carries. Each is drawn at its own size rather than
/// downsampled from the master, which is what keeps the 16pt one from turning
/// to mush.
let renditions: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent()  // Scripts/
    .deletingLastPathComponent()
let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

do {
    if let path = option("--png") {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = URL(fileURLWithPath: path, relativeTo: cwd)
        try writePNG(render(size: option("--size").flatMap(Int.init) ?? 1024), to: url)
        print("wrote \(url.path)")
        exit(0)
    }

    let fm = FileManager.default
    let iconset = fm.temporaryDirectory.appendingPathComponent("ClaudeIsland.iconset")
    try? fm.removeItem(at: iconset)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for rendition in renditions {
        try writePNG(
            render(size: rendition.size),
            to: iconset.appendingPathComponent("\(rendition.name).png"))
    }

    let resources = root.appendingPathComponent("Resources")
    try fm.createDirectory(at: resources, withIntermediateDirectories: true)
    let icns = resources.appendingPathComponent("AppIcon.icns")

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw Failure("iconutil failed") }
    try? fm.removeItem(at: iconset)

    print("wrote \(icns.path)")
} catch {
    FileHandle.standardError.write("make-icon: \(error)\n".data(using: .utf8)!)
    exit(1)
}
