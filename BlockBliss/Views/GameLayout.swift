import SwiftUI

/// All geometry of the game screen, derived from the size of the safe area.
///
/// Everything is expressed in the "game" coordinate space (origin = top-left of the safe area), which is
/// also the space the drag gesture reports in. Computing the layout up front (instead of reading frames
/// back through preferences) keeps hit-testing and snapping exact and makes the screen deterministic
/// from iPhone SE (375x667) up to Pro Max (440x956).
struct GameLayout: Equatable {
    static let coordinateSpace = "game"
    /// Board frame thickness and the gap between cells, in points (SPEC "Look").
    static let frameWidth: CGFloat = 5
    static let gap: CGFloat = 2
    /// The lifted piece's bottom edge floats this far (plus one cell) above the finger.
    static let liftClearance: CGFloat = 30
    /// The tallest/widest piece is 5 cells long.
    private static let maxPieceCells: CGFloat = 5
    private static let preferredTrayScale: CGFloat = 0.6

    let size: CGSize
    let hudHeight: CGFloat
    let boardRect: CGRect
    /// Edge of one board cell.
    let cell: CGFloat
    let trayRect: CGRect
    /// Size of tray pieces relative to board cells (0.6 unless the screen is too narrow for a 5-long piece).
    let trayScale: CGFloat

    init(size: CGSize) {
        self.size = size
        let w = size.width, h = size.height
        let f = Self.frameWidth, g = Self.gap

        let hud = (h * 0.17).clamped(96, 140)
        let slotWidth = w / 3
        let minGap: CGFloat = 14

        /// Cell size snapped to half points (crisp edges), the matching tray scale and tray height.
        func metrics(side: CGFloat) -> (cell: CGFloat, scale: CGFloat, trayHeight: CGFloat) {
            let raw = (side - 2 * f - 7 * g) / 8
            let cell = (raw * 2).rounded(.down) / 2
            let pitch = cell + g
            let scale = min(Self.preferredTrayScale, (slotWidth - 12) / (Self.maxPieceCells * pitch))
            return (cell, scale, Self.maxPieceCells * scale * pitch + 20)
        }

        // Start from ~90% of the width and shrink until HUD + board + tray fit with breathing room.
        var side = w * 0.9
        var m = metrics(side: side)
        while hud + side + m.trayHeight + 3 * minGap > h && side > 180 {
            side -= 2
            m = metrics(side: side)
        }

        let boardSide = 8 * m.cell + 7 * g + 2 * f
        let remaining = max(0, h - hud - boardSide - m.trayHeight)
        // Spare height goes mostly below the tray so it sits at roughly 75-80% of the screen on tall phones.
        let gapAboveBoard = remaining * 0.20
        let gapBelowBoard = remaining * 0.30

        hudHeight = hud
        cell = m.cell
        trayScale = m.scale
        boardRect = CGRect(x: ((w - boardSide) / 2).rounded(), y: (hud + gapAboveBoard).rounded(),
                           width: boardSide, height: boardSide)
        trayRect = CGRect(x: 0, y: (boardRect.maxY + gapBelowBoard).rounded(), width: w, height: m.trayHeight)
    }

    // MARK: Board geometry

    var pitch: CGFloat { cell + Self.gap }
    var gap: CGFloat { Self.gap }
    var boardSide: CGFloat { boardRect.width }

    /// Top-left of cell (0,0) in game space.
    var boardInnerOrigin: CGPoint {
        CGPoint(x: boardRect.minX + Self.frameWidth, y: boardRect.minY + Self.frameWidth)
    }

    /// Cell rect relative to the board's own top-left (used by the board and effects canvases).
    func localCellRect(row: Int, col: Int) -> CGRect {
        CGRect(x: Self.frameWidth + CGFloat(col) * pitch,
               y: Self.frameWidth + CGFloat(row) * pitch,
               width: cell, height: cell)
    }

    // MARK: Tray geometry

    var slotWidth: CGFloat { trayRect.width / 3 }

    func slotRect(_ index: Int) -> CGRect {
        CGRect(x: trayRect.minX + CGFloat(index) * slotWidth, y: trayRect.minY, width: slotWidth, height: trayRect.height)
    }

    func slotCenter(_ index: Int) -> CGPoint {
        let r = slotRect(index)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// Which slot a touch belongs to. The whole slot (and a little margin above/below the tray) counts,
    /// not just the piece's filled cells, so small pieces are easy to grab.
    func slotIndex(at point: CGPoint) -> Int? {
        let hit = trayRect.insetBy(dx: 0, dy: -14)
        guard hit.contains(point) else { return nil }
        return Int(((point.x - trayRect.minX) / slotWidth).rounded(.down)).clamped(0, 2)
    }

    // MARK: Dragging

    /// Distance from the finger up to the lifted piece's bottom edge.
    var liftOffset: CGFloat { pitch + Self.liftClearance }

    /// Size of a piece at 1.0x board scale.
    func pieceSize(_ shape: Shape) -> CGSize {
        PieceView.size(of: shape, cell: cell, gap: gap)
    }

    /// Top-left of the floating piece for a given finger position (game space).
    func floatingTopLeft(finger: CGPoint, shape: Shape) -> CGPoint {
        let s = pieceSize(shape)
        return CGPoint(x: finger.x - s.width / 2, y: finger.y - liftOffset - s.height)
    }

    /// Centre of the floating piece for a given finger position.
    func floatingCenter(finger: CGPoint, shape: Shape) -> CGPoint {
        let s = pieceSize(shape)
        return CGPoint(x: finger.x, y: finger.y - liftOffset - s.height / 2)
    }

    /// The board origin the piece would snap to: its floating top-left, rounded to the nearest cell.
    func snappedOrigin(finger: CGPoint, shape: Shape) -> Cell {
        let tl = floatingTopLeft(finger: finger, shape: shape)
        let o = boardInnerOrigin
        return Cell(row: Int(((tl.y - o.y) / pitch).rounded()),
                    col: Int(((tl.x - o.x) / pitch).rounded()))
    }

    /// Centre of a board cell in game space.
    func cellCenter(_ cell: Cell) -> CGPoint {
        let o = boardInnerOrigin
        return CGPoint(x: o.x + CGFloat(cell.col) * pitch + self.cell / 2,
                       y: o.y + CGFloat(cell.row) * pitch + self.cell / 2)
    }
}
