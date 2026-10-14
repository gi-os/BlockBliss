import SwiftUI

/// Immediate-mode drawing of the bevelled Block Blast tile. Every surface that shows blocks
/// (board, tray, dragged piece, clear effects) goes through `BlockArt.draw`, so a tile looks
/// identical everywhere and is cheap: six path fills and one hairline stroke.
enum BlockArt {
    /// Bevel width as a fraction of the tile (SPEC: about 14%).
    static let bevelRatio: CGFloat = 0.14

    static func draw(in context: GraphicsContext, rect: CGRect, palette: BlockPalette, opacity: Double = 1) {
        var ctx = context
        if opacity < 1 { ctx.opacity = opacity }

        let b = max(1, rect.width * bevelRatio)
        let inner = rect.insetBy(dx: b, dy: b)

        // Four mitred trapezoids, one per side. Corner points are shared so the joins are exact.
        var top = Path()
        top.move(to: CGPoint(x: rect.minX, y: rect.minY))
        top.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        top.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
        top.addLine(to: CGPoint(x: inner.minX, y: inner.minY))
        top.closeSubpath()

        var left = Path()
        left.move(to: CGPoint(x: rect.minX, y: rect.minY))
        left.addLine(to: CGPoint(x: inner.minX, y: inner.minY))
        left.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
        left.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        left.closeSubpath()

        var right = Path()
        right.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        right.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        right.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
        right.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
        right.closeSubpath()

        var bottom = Path()
        bottom.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        bottom.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
        bottom.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
        bottom.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        bottom.closeSubpath()

        ctx.fill(top, with: .color(palette.top))
        ctx.fill(left, with: .color(palette.left))
        ctx.fill(right, with: .color(palette.right))
        ctx.fill(bottom, with: .color(palette.bottom))

        // Face: a slight top-to-bottom gradient.
        ctx.fill(
            Path(inner),
            with: .linearGradient(
                Gradient(colors: [palette.faceTop, palette.faceBottom]),
                startPoint: CGPoint(x: inner.midX, y: inner.minY),
                endPoint: CGPoint(x: inner.midX, y: inner.maxY)))

        // Thin dark outline.
        ctx.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(palette.outline), lineWidth: 1)
    }

    /// Soft white glow around a tile: marks blocks that would clear (never colour alone).
    static func drawGlow(in context: GraphicsContext, rect: CGRect, strength: Double = 1) {
        context.stroke(Path(rect.insetBy(dx: -1.5, dy: -1.5)),
                       with: .color(.white.opacity(0.28 * strength)), lineWidth: 5)
        context.stroke(Path(rect.insetBy(dx: 0.75, dy: 0.75)),
                       with: .color(.white.opacity(0.95 * strength)), lineWidth: 2)
    }
}

/// A single bevelled tile, for previews and small icons.
struct BlockView: View {
    let color: BlockColor

    var body: some View {
        Canvas { ctx, size in
            BlockArt.draw(in: ctx, rect: CGRect(origin: .zero, size: size), palette: color.palette)
        }
        .accessibilityHidden(true)
    }
}

/// A whole piece drawn at an arbitrary scale. `cell` and `gap` are the (already scaled) tile edge and
/// inter-tile gap, so the same view serves the tray (0.6x) and the lifted piece (1.0x).
struct PieceView: View {
    let shape: Shape
    let color: BlockColor
    let cell: CGFloat
    let gap: CGFloat

    static func size(of shape: Shape, cell: CGFloat, gap: CGFloat) -> CGSize {
        CGSize(width: CGFloat(shape.width) * (cell + gap) - gap,
               height: CGFloat(shape.height) * (cell + gap) - gap)
    }

    var body: some View {
        let size = Self.size(of: shape, cell: cell, gap: gap)
        Canvas { ctx, _ in
            let palette = color.palette
            let pitch = cell + gap
            for c in shape.cells {
                let rect = CGRect(x: CGFloat(c.col) * pitch, y: CGFloat(c.row) * pitch, width: cell, height: cell)
                BlockArt.draw(in: ctx, rect: rect, palette: palette)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}
