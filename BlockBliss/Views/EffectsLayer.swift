import SwiftUI

/// Everything that animates over the board after a move: the clear animation (flash, shrink/fade,
/// shards, line sweeps) drawn in one Canvas, plus the "+N", praise and "Combo N" popups.
/// The canvas is driven by a TimelineView that is paused whenever no effect is active.
struct EffectsLayer: View {
    @Environment(GameViewModel.self) private var vm
    let layout: GameLayout

    var body: some View {
        let effects = vm.effects
        let layout = layout

        ZStack {
            TimelineView(.animation(minimumInterval: nil, paused: effects.isEmpty)) { timeline in
                Canvas { ctx, _ in
                    for effect in effects {
                        let t = max(0, timeline.date.timeIntervalSince(effect.start))
                        if effect.isClear {
                            Self.drawClear(effect, t: t, in: ctx, layout: layout)
                        } else {
                            Self.drawSettle(effect, t: t, in: ctx, layout: layout)
                        }
                    }
                }
            }

            ForEach(effects) { effect in
                if effect.isClear {
                    EffectPopups(effect: effect, layout: layout)
                }
            }
        }
        .frame(width: layout.boardSide, height: layout.boardSide)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Drawing

    /// A quick white flash on a placement that clears nothing.
    private static func drawSettle(_ effect: MoveEffect, t: Double, in ctx: GraphicsContext, layout: GameLayout) {
        let duration = 0.3
        guard t < duration else { return }
        let alpha = 0.5 * (1 - t / duration)
        for cell in effect.placed {
            let rect = layout.localCellRect(row: cell.row, col: cell.col)
            ctx.fill(Path(rect), with: .color(.white.opacity(alpha)))
        }
    }

    // Timing of the full clear animation, in seconds.
    private static let flashDuration = 0.10     // cell turns white
    private static let shrinkDuration = 0.35    // then shrinks and fades
    private static let staggerPerCell = 0.03    // delay per cell of distance from the drop point
    private static let shardLife = 0.55

    private static func drawClear(_ effect: MoveEffect, t: Double, in ctx: GraphicsContext, layout: GameLayout) {
        let drop = effect.dropCenter
        let f = GameLayout.frameWidth
        let inner = CGRect(x: f, y: f, width: layout.boardSide - 2 * f, height: layout.boardSide - 2 * f)

        // Reduce Effects: a plain, short fade. No stagger, no particles, no sweep.
        if effect.reduced {
            let p = ((t - 0.05) / 0.30).clamped(0, 1)
            guard p < 1 else { return }
            for cc in effect.cleared {
                let rect = layout.localCellRect(row: cc.cell.row, col: cc.cell.col)
                BlockArt.draw(in: ctx, rect: rect, palette: cc.color.palette, opacity: 1 - p)
            }
            return
        }

        // All Clear: a soft white wash over the whole board.
        if effect.isAllClear, t < 0.6 {
            ctx.fill(Path(inner), with: .color(.white.opacity(0.22 * (1 - t / 0.6))))
        }

        let shardsPerCell = effect.cleared.count > 24 ? 2 : 3

        for cc in effect.cleared {
            let rect = layout.localCellRect(row: cc.cell.row, col: cc.cell.col)
            let palette = cc.color.palette
            // Staggered outward from the drop point.
            let dist = hypot(CGFloat(cc.cell.col) - drop.x, CGFloat(cc.cell.row) - drop.y)
            let local = t - Double(dist) * staggerPerCell

            if local < 0 {
                // Waiting for the wave to arrive: still a normal block.
                BlockArt.draw(in: ctx, rect: rect, palette: palette)
                continue
            }

            let shrink = ((local - flashDuration) / shrinkDuration).clamped(0, 1)
            if shrink < 1 {
                let flash = (local / flashDuration).clamped(0, 1)
                let scale = 1 - 0.85 * shrink * shrink
                let r = rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
                let alpha = 1 - shrink
                BlockArt.draw(in: ctx, rect: r, palette: palette, opacity: alpha)
                ctx.fill(Path(r), with: .color(.white.opacity(flash * alpha)))
            }

            // Shards leave the cell the moment it starts to shrink.
            let tau = local - flashDuration
            if tau > 0, tau < shardLife {
                drawShards(cell: cc, rect: rect, tau: tau, effectID: effect.id, count: shardsPerCell,
                           palette: palette, cellSize: layout.cell, in: ctx)
            }
        }

        // A bright band sweeps along every cleared line, over a faint wash of the whole line.
        let sweep = ((t - 0.02) / 0.40).clamped(0, 1)
        if sweep > 0, sweep < 1 {
            for row in effect.rows {
                let line = CGRect(x: inner.minX, y: layout.localCellRect(row: row, col: 0).minY,
                                  width: inner.width, height: layout.cell)
                drawSweep(line: line, progress: sweep, horizontal: true, pitch: layout.pitch, in: ctx)
            }
            for col in effect.cols {
                let line = CGRect(x: layout.localCellRect(row: 0, col: col).minX, y: inner.minY,
                                  width: layout.cell, height: inner.height)
                drawSweep(line: line, progress: sweep, horizontal: false, pitch: layout.pitch, in: ctx)
            }
        }
    }

    private static func drawShards(cell: ClearedCell, rect: CGRect, tau: Double, effectID: Int, count: Int,
                                   palette: BlockPalette, cellSize: CGFloat, in ctx: GraphicsContext) {
        let k = cellSize / 40            // scale motion with the board size
        let life = tau / shardLife
        for i in 0..<count {
            // Deterministic per shard, so every frame draws the same trajectory.
            var rng = SeededRNG(seed: UInt64(effectID) &* 7919 &+ UInt64(cell.cell.bit) &* 104_729 &+ UInt64(i) &* 31)
            let angle = rng.nextUnit() * 2 * .pi
            let speed = (70 + rng.nextUnit() * 160) * k
            let spin = (rng.nextUnit() - 0.5) * 16
            let size = cellSize * (0.15 + 0.12 * rng.nextUnit()) * (1 - 0.4 * life)

            let x = rect.midX + CGFloat(cos(angle) * speed * tau)
            let y = rect.midY + CGFloat(sin(angle) * speed * tau - 40 * k * tau + 0.5 * 700 * k * tau * tau)

            var s = ctx
            s.opacity = 1 - life
            s.translateBy(x: x, y: y)
            s.rotate(by: .radians(spin * tau))
            s.fill(Path(CGRect(x: -size / 2, y: -size / 2, width: size, height: size * 0.7)),
                   with: .color(i % 2 == 0 ? palette.face : palette.top))
        }
    }

    private static func drawSweep(line: CGRect, progress: Double, horizontal: Bool, pitch: CGFloat,
                                  in ctx: GraphicsContext) {
        // Faint wash over the line that fades with the sweep.
        ctx.fill(Path(line), with: .color(.white.opacity(0.25 * (1 - progress))))

        let eased = 1 - pow(1 - progress, 2)
        let bandLength = pitch * 3
        let travel = (horizontal ? line.width : line.height) + bandLength
        let start = (horizontal ? line.minX : line.minY) - bandLength + travel * eased

        let band = horizontal
            ? CGRect(x: start, y: line.minY, width: bandLength, height: line.height)
            : CGRect(x: line.minX, y: start, width: line.width, height: bandLength)
        let visible = band.intersection(line)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        let gradient = Gradient(colors: [.white.opacity(0), .white.opacity(0.9), .white.opacity(0)])
        let from = horizontal ? CGPoint(x: band.minX, y: band.midY) : CGPoint(x: band.midX, y: band.minY)
        let to = horizontal ? CGPoint(x: band.maxX, y: band.midY) : CGPoint(x: band.midX, y: band.maxY)
        ctx.fill(Path(visible), with: .linearGradient(gradient, startPoint: from, endPoint: to))
    }
}

// MARK: - Popups

/// The "+N" score, the praise word and the "Combo N" banner for one clearing move.
private struct EffectPopups: View {
    let effect: MoveEffect
    let layout: GameLayout

    var body: some View {
        let side = layout.boardSide
        let center = effect.clearCenter
        // Cell units -> board-local points.
        let pointsAt = CGPoint(x: GameLayout.frameWidth + (center.x + 0.5) * layout.pitch,
                               y: GameLayout.frameWidth + (center.y + 0.5) * layout.pitch)

        ZStack {
            Text("+\(effect.points)")
                .font(Theme.rounded(layout.cell * 0.85))
                .foregroundStyle(.white)
                .shadow(color: Color(hex: 0xF08A00), radius: 0, x: 0, y: 3)
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
                .modifier(PopModifier(hold: 0.7, rise: 46, reduced: effect.reduced))
                .position(pointsAt)

            if let praise = effect.praise {
                PraiseText(praise: praise, allClearBonus: effect.allClearBonus, fontSize: side * 0.115)
                    .modifier(PopModifier(hold: 1.0, rise: 0, reduced: effect.reduced))
                    .position(x: side / 2, y: side * (effect.comboAfter >= 2 ? 0.40 : 0.46))
            }

            if effect.comboAfter >= 2 {
                ComboBanner(combo: effect.comboAfter, fontSize: side * 0.07)
                    .modifier(PopModifier(hold: 1.0, rise: 0, reduced: effect.reduced))
                    .position(x: side / 2, y: side * (effect.praise == nil ? 0.46 : 0.58))
            }
        }
        .frame(width: side, height: side)
    }
}

struct PraiseText: View {
    let praise: Praise
    let allClearBonus: Int
    let fontSize: CGFloat

    var body: some View {
        VStack(spacing: 2) {
            Text(praise.text)
                .font(Theme.rounded(fontSize))
                .italic()
                .foregroundStyle(praise == .unbelievable ? AnyShapeStyle(Theme.rainbow) : AnyShapeStyle(Color.white))
                .shadow(color: .black.opacity(0.4), radius: 0, x: 0, y: 4)
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
            if allClearBonus > 0 {
                Text("All Clear +\(allClearBonus)")
                    .font(Theme.rounded(fontSize * 0.45))
                    .foregroundStyle(Theme.bestScore)
                    .shadow(color: .black.opacity(0.4), radius: 0, x: 0, y: 2)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

/// "Combo N": chunky italic white word, big yellow number.
struct ComboBanner: View {
    let combo: Int
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text("Combo")
                .font(Theme.rounded(fontSize))
                .italic()
                .foregroundStyle(.white)
            Text("\(combo)")
                .font(Theme.rounded(fontSize * 1.8))
                .italic()
                .foregroundStyle(Theme.bestScore)
        }
        .shadow(color: .black.opacity(0.4), radius: 0, x: 0, y: 3)
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
    }
}

/// Pops a view in (spring scale 0.6 -> ~1.1 -> 1.0), holds it, then fades it out. With Reduce Effects it is
/// just a short fade in and out.
private struct PopModifier: ViewModifier {
    let hold: Double
    let rise: CGFloat
    let reduced: Bool

    @State private var scale: CGFloat = 0.6
    @State private var opacity: Double = 0
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(reduced ? 1 : scale)
            .opacity(opacity)
            .offset(y: offset)
            .task {
                if reduced {
                    withAnimation(.easeOut(duration: 0.15)) { opacity = 1 }
                    try? await Task.sleep(for: .seconds(hold))
                    withAnimation(.easeIn(duration: 0.3)) { opacity = 0 }
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.42)) { scale = 1 }
                    withAnimation(.easeOut(duration: 0.12)) { opacity = 1 }
                    if rise > 0 { withAnimation(.easeOut(duration: hold + 0.3)) { offset = -rise } }
                    try? await Task.sleep(for: .seconds(hold))
                    withAnimation(.easeIn(duration: 0.3)) { opacity = 0 }
                }
            }
    }
}

// MARK: - Board shake

/// Brief decaying shake. `phase` is animated from n to n+1; the shake is zero at whole numbers, so the
/// board always comes to rest exactly where it started.
struct ShakeEffect: GeometryEffect {
    var amplitude: CGFloat
    var phase: CGFloat

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let f = phase - phase.rounded(.down)
        let decay = 1 - f
        let x = amplitude * decay * sin(f * .pi * 8)
        let y = amplitude * 0.5 * decay * sin(f * .pi * 6 + 1)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: y))
    }
}
