import SwiftUI

/// The 8x8 board, drawn in a single Canvas (frame, empty cells, blocks, drop preview) so 64 cells plus
/// a drag stay cheap. It only redraws when the board or the drop preview changes, never per finger move.
struct BoardView: View {
    @Environment(GameViewModel.self) private var vm
    let layout: GameLayout

    var body: some View {
        let board = vm.state.board
        let preview = vm.drag.preview
        let layout = layout

        Canvas { ctx, size in
            Self.draw(in: ctx, size: size, board: board, preview: preview, layout: layout)
        }
        .frame(width: layout.boardSide, height: layout.boardSide)
        .accessibilityElement()
        .accessibilityLabel("Game board")
        .accessibilityValue("\(board.filledCount) of \(Board.cellCount) cells filled")
    }

    private static func draw(in ctx: GraphicsContext, size: CGSize, board: Board,
                             preview: DropPreview?, layout: GameLayout) {
        let f = GameLayout.frameWidth

        // Frame and the gap colour behind the cells.
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6), with: .color(Theme.boardFrame))
        ctx.fill(Path(roundedRect: CGRect(x: f, y: f, width: size.width - 2 * f, height: size.height - 2 * f),
                      cornerRadius: 2),
                 with: .color(Theme.boardGap))

        // Blocks that belong to a line the dragged piece would complete take the piece's colour.
        var litMask: UInt64 = 0
        if let preview {
            for r in preview.rows { litMask |= BitBoard.rowMask(r) }
            for c in preview.cols { litMask |= BitBoard.colMask(c) }
        }

        var litRects: [CGRect] = []
        for row in 0..<Board.size {
            for col in 0..<Board.size {
                let rect = layout.localCellRect(row: row, col: col)
                if let color = board[row, col] {
                    // litMask is 0 when there is no preview, so `lit` implies a preview exists.
                    let lit = litMask & (1 << UInt64(row * Board.size + col)) != 0
                    let shown = lit ? (preview?.color ?? color) : color
                    BlockArt.draw(in: ctx, rect: rect, palette: shown.palette)
                    if lit { litRects.append(rect) }
                } else {
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Theme.emptyCell))
                }
            }
        }

        // Glow outlines go on top so neighbouring tiles never paint over them.
        for rect in litRects { BlockArt.drawGlow(in: ctx, rect: rect) }

        // Ghost of the piece at its snapped spot: translucent fill with a crisp near-white outline.
        if let preview {
            for cell in preview.cells {
                let rect = layout.localCellRect(row: cell.row, col: cell.col)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.18)))
                ctx.stroke(Path(rect.insetBy(dx: 0.75, dy: 0.75)), with: .color(.white.opacity(0.92)), lineWidth: 1.5)
            }
        }
    }
}
