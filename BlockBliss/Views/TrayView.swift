import SwiftUI

/// The three tray slots. The slots are passive: one gesture in `GameView` covers the whole tray and
/// decides which slot a touch belongs to, so the hit area is the whole slot, not the piece's cells.
struct TrayView: View {
    @Environment(GameViewModel.self) private var vm
    @Environment(Settings.self) private var settings
    let layout: GameLayout

    var body: some View {
        let tray = vm.state.tray
        let held = vm.drag.trayIndex
        let ids = tray.map { $0?.id }

        ZStack(alignment: .topLeading) {
            ForEach(0..<3, id: \.self) { index in
                slot(index, piece: tray[index], isHeld: held == index)
            }
        }
        .frame(width: layout.trayRect.width, height: layout.trayRect.height, alignment: .topLeading)
        // New trays pop in; removal is instant because the lifted piece was already on screen.
        .animation(settings.reduceEffects ? .easeOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.72),
                   value: ids)
    }

    @ViewBuilder
    private func slot(_ index: Int, piece: Piece?, isHeld: Bool) -> some View {
        let rect = layout.slotRect(index)
        let placeable = piece != nil && vm.isPlaceable(trayIndex: index)

        ZStack {
            if let piece {
                PieceView(shape: piece.shape, color: piece.color,
                          cell: layout.cell * layout.trayScale, gap: layout.gap * layout.trayScale)
                    // The slot stays empty while its piece is in the player's hand.
                    .opacity(isHeld ? 0 : (placeable ? 1 : 0.35))
                    .id(piece.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.5).combined(with: .opacity), removal: .identity))
            }
        }
        .frame(width: rect.width, height: rect.height)
        .offset(x: rect.minX - layout.trayRect.minX)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.description(of: piece, slot: index, placeable: placeable))
    }

    private static func description(of piece: Piece?, slot: Int, placeable: Bool) -> String {
        guard let piece else { return "Slot \(slot + 1), empty" }
        let size = "\(piece.shape.cellCount) blocks, \(piece.shape.width) wide, \(piece.shape.height) tall"
        return "Slot \(slot + 1), \(piece.color.spokenName) piece, \(size)" + (placeable ? "" : ", does not fit anywhere")
    }
}

// MARK: - Lifted piece

/// The piece in the player's hand, drawn above everything else at 1.0x board scale, floating above the finger.
struct DragLayer: View {
    @Environment(GameViewModel.self) private var vm
    let layout: GameLayout

    var body: some View {
        let drag = vm.drag
        ZStack(alignment: .topLeading) {
            if let index = drag.trayIndex, let piece = vm.state.tray[index] {
                let size = layout.pieceSize(piece.shape)
                PieceView(shape: piece.shape, color: piece.color, cell: layout.cell, gap: layout.gap)
                    // Soft shadow in the piece's own colour.
                    .shadow(color: piece.color.palette.face.opacity(0.55), radius: 9, x: 0, y: 7)
                    .modifier(LiftEffect(
                        lift: drag.lift,
                        slotCenter: layout.slotCenter(index),
                        floatCenter: layout.floatingCenter(finger: drag.finger, shape: piece.shape),
                        restScale: layout.trayScale))
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .id(drag.pickID)
                    // Start the lift animation only after the piece has been drawn once at rest.
                    .onAppear { vm.raiseHeldPiece() }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Moves and scales a view between its tray slot (lift = 0) and the floating position above the finger
/// (lift = 1). Only `lift` is animatable, so the finger itself is tracked without any lag while the
/// pick-up and spring-back animate smoothly.
private struct LiftEffect: GeometryEffect {
    var lift: CGFloat
    let slotCenter: CGPoint
    let floatCenter: CGPoint
    let restScale: CGFloat

    var animatableData: CGFloat {
        get { lift }
        set { lift = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let cx = slotCenter.x + (floatCenter.x - slotCenter.x) * lift
        let cy = slotCenter.y + (floatCenter.y - slotCenter.y) * lift
        let scale = restScale + (1 - restScale) * lift
        // The view sits at the layer's top-left; scale about its own centre, then move that centre to (cx, cy).
        var t = CGAffineTransform(translationX: cx, y: cy)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -size.width / 2, y: -size.height / 2)
        return ProjectionTransform(t)
    }
}
