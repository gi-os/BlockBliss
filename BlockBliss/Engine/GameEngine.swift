import Foundation

/// The rules of one Classic run: validates placements, scores them, tracks the streak, deals new trays
/// and detects game over. Pure value type; all of its state lives in `GameState`, which is `Codable`, so
/// a run can be saved after every move and resumed exactly.
public struct GameEngine {
    public private(set) var state: GameState

    /// A fresh game with the first tray dealt.
    public init(seed: UInt64) {
        var fresh = GameState(seed: seed)
        Self.dealTray(into: &fresh)
        state = fresh
    }

    /// Resumes a saved run. Never re-deals a tray that has pieces left, so a relaunch can't re-roll it.
    /// Only a tray that is empty on a live game (which a normal save never produces) gets dealt.
    public init(restoring state: GameState) {
        var restored = state
        if !restored.isGameOver {
            if restored.tray.count != 3 {
                restored.tray = Array((restored.tray + [nil, nil, nil]).prefix(3))
            }
            if restored.tray.allSatisfy({ $0 == nil }) {
                Self.dealTray(into: &restored)
            }
            restored.isGameOver = !Self.hasMove(restored)
        }
        self.state = restored
    }

    // MARK: Queries (used by the UI while dragging)

    public func canPlace(trayIndex: Int, at origin: Cell) -> Bool {
        guard !state.isGameOver, let piece = piece(at: trayIndex) else { return false }
        return state.board.canPlace(piece.shape, at: origin)
    }

    /// Rows and columns that would clear if the piece were dropped here (for the pre-drop highlight).
    public func linesCompleted(trayIndex: Int, at origin: Cell) -> (rows: [Int], cols: [Int]) {
        guard let piece = piece(at: trayIndex) else { return ([], []) }
        return state.board.linesCompleted(by: piece.shape, at: origin)
    }

    /// False when the piece is gone from the tray or fits nowhere right now (the UI dims it).
    public func isPlaceableAnywhere(trayIndex: Int) -> Bool {
        guard let piece = piece(at: trayIndex) else { return false }
        return state.board.hasAnyPlacement(for: piece.shape)
    }

    // MARK: Move

    /// Places the tray piece at `origin`. Returns nil, changing nothing, if the move is invalid.
    @discardableResult
    public mutating func place(trayIndex: Int, at origin: Cell) -> MoveOutcome? {
        guard canPlace(trayIndex: trayIndex, at: origin), let piece = state.tray[trayIndex] else { return nil }

        // Board: place, then every full row and column clears at once.
        let clear = state.board.place(piece.shape, color: piece.color, at: origin)
        let lines = clear.linesCleared
        let boardCleared = lines > 0 && state.board.isEmpty

        // Score: 1 per cell, line clear scored with the combo *before* this move, flat All Clear bonus.
        let comboBefore = state.combo
        let placementPoints = piece.shape.cellCount
        let clearPoints = Scoring.clearPoints(lines: lines, comboBefore: comboBefore)
        let allClearBonus = boardCleared ? Scoring.allClearBonus : 0

        // Streak: rolling window counted continuously across trays.
        let streak = Scoring.advanceCombo(combo: comboBefore, movesSinceClear: state.movesSinceClear, linesCleared: lines)
        state.combo = streak.combo
        state.movesSinceClear = streak.movesSinceClear

        state.score += placementPoints + clearPoints + allClearBonus
        state.piecesPlaced += 1
        state.linesCleared += lines
        state.bestComboThisGame = max(state.bestComboThisGame, streak.combo)
        if boardCleared { state.allClears += 1 }

        state.tray[trayIndex] = nil
        var newTrayDealt = false
        if state.tray.allSatisfy({ $0 == nil }) {
            Self.dealTray(into: &state)       // uses the post-move board and score
            newTrayDealt = true
        }
        state.isGameOver = !Self.hasMove(state)

        return MoveOutcome(
            trayIndex: trayIndex,
            piece: piece,
            origin: origin,
            clear: clear,
            placementPoints: placementPoints,
            clearPoints: clearPoints,
            allClearBonus: allClearBonus,
            comboBefore: comboBefore,
            comboAfter: streak.combo,
            comboBroken: streak.broken,
            boardCleared: boardCleared,
            praise: Scoring.praise(lines: lines, boardCleared: boardCleared),
            newTrayDealt: newTrayDealt,
            isGameOver: state.isGameOver,
            scoreAfter: state.score)
    }

    // MARK: Helpers

    private func piece(at trayIndex: Int) -> Piece? {
        guard state.tray.indices.contains(trayIndex) else { return nil }
        return state.tray[trayIndex]
    }

    /// True if at least one remaining tray piece fits somewhere.
    private static func hasMove(_ state: GameState) -> Bool {
        state.tray.contains { piece in
            piece.map { state.board.hasAnyPlacement(for: $0.shape) } ?? false
        }
    }

    /// Deals a fresh tray from the generator and updates the round counter and repetition history.
    private static func dealTray(into state: inout GameState) {
        let deal = PieceGenerator.deal(board: state.board, score: state.score, round: state.round,
                                       history: state.trayHistory, rng: &state.rng, colorRNG: &state.colorRNG)
        state.tray = deal.pieces.map { Optional($0) }
        state.round += 1
        state.trayHistory.append(deal.pieces.map { $0.shape.id })
        if state.trayHistory.count > 2 { state.trayHistory.removeFirst(state.trayHistory.count - 2) }
    }
}
