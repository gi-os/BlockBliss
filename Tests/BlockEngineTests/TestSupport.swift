import XCTest
@testable import BlockEngine

// Shared helpers for the engine tests.

func shape(_ id: String) -> Shape {
    guard let found = ShapeCatalog.shape(id: id) else { fatalError("unknown shape id \(id)") }
    return found
}

/// A board with exactly the cells of `occupancy` filled.
func board(from occupancy: UInt64) -> Board {
    let rows = (0..<8).map { r in
        String((0..<8).map { c in occupancy & (1 << UInt64(r * 8 + c)) != 0 ? Character("X") : Character(".") })
    }
    return Board(rows: rows)
}

let slotColors: [BlockColor] = [.red, .green, .blue]

/// Builds an engine from a hand-made position. `tray` holds shape ids (nil = already placed).
func makeEngine(rows: [String], tray: [String?], combo: Int = 0, movesSinceClear: Int = 0,
                score: Int = 0, round: Int = 1, seed: UInt64 = 7) -> GameEngine {
    var state = GameState(seed: seed)
    state.board = Board(rows: rows)
    state.tray = tray.enumerated().map { i, id in id.map { Piece(shape: shape($0), color: slotColors[i % 3]) } }
    state.combo = combo
    state.movesSinceClear = movesSinceClear
    state.score = score
    state.round = round
    return GameEngine(restoring: state)
}

/// Rows of "X"/"." with the given cells filled, everything else empty.
func rows(filled cells: [(Int, Int)]) -> [String] {
    var grid = [[Character]](repeating: [Character](repeating: ".", count: 8), count: 8)
    for (r, c) in cells { grid[r][c] = "X" }
    return grid.map { String($0) }
}

/// Compares everything about a run except the random per-deal piece UUIDs.
struct StateSignature: Equatable {
    var board: Board
    var tray: [String?]
    var trayColors: [BlockColor?]
    var score, combo, movesSinceClear, round, piecesPlaced, linesCleared, bestCombo, allClears: Int
    var seed: UInt64
    var rng, colorRNG: SeededRNG
    var history: [[String]]
    var isGameOver: Bool
    var generatorVersion: Int

    init(_ s: GameState) {
        board = s.board
        tray = s.tray.map { $0?.shape.id }
        trayColors = s.tray.map { $0?.color }
        score = s.score; combo = s.combo; movesSinceClear = s.movesSinceClear; round = s.round
        piecesPlaced = s.piecesPlaced; linesCleared = s.linesCleared; bestCombo = s.bestComboThisGame
        allClears = s.allClears
        seed = s.seed; rng = s.rng; colorRNG = s.colorRNG; history = s.trayHistory
        isGameOver = s.isGameOver; generatorVersion = s.generatorVersion
    }
}

// MARK: - Deterministic movers

/// Plays pseudo-random legal moves. Three styles give the generator very different boards to deal onto:
///  - `random`: any legal move (messy, short games);
///  - `lineSeeking`: random, but always takes a move that clears the most lines when one exists;
///  - `greedy`: bitboard heuristic (clear lines, keep the board smooth, avoid holes), so games run long and
///    the difficulty ramp is reached.
struct Mover {
    enum Style { case random, lineSeeking, greedy }

    var rng: SeededRNG
    var style: Style

    init(seed: UInt64, style: Style) {
        rng = SeededRNG(seed: seed)
        self.style = style
    }

    init(seed: UInt64, seeksLines: Bool) {
        self.init(seed: seed, style: seeksLines ? .lineSeeking : .random)
    }

    mutating func next(_ engine: GameEngine) -> (trayIndex: Int, origin: Cell)? {
        style == .greedy ? greedyMove(engine) : randomMove(engine)
    }

    private mutating func randomMove(_ engine: GameEngine) -> (trayIndex: Int, origin: Cell)? {
        var options: [(trayIndex: Int, origin: Cell, lines: Int)] = []
        for i in 0..<3 {
            guard let piece = engine.state.tray[i] else { continue }
            for origin in engine.state.board.validOrigins(for: piece.shape) {
                let done = engine.linesCompleted(trayIndex: i, at: origin)
                options.append((i, origin, done.rows.count + done.cols.count))
            }
        }
        guard !options.isEmpty else { return nil }
        if style == .lineSeeking, let most = options.map(\.lines).max(), most > 0 {
            options = options.filter { $0.lines == most }
        }
        let pick = options[Int(rng.next() % UInt64(options.count))]
        return (pick.trayIndex, pick.origin)
    }

    /// One-ply greedy: most lines first, then the smoothest board with the fewest walled-in holes.
    private func greedyMove(_ engine: GameEngine) -> (trayIndex: Int, origin: Cell)? {
        let occupancy = engine.state.board.occupancy
        var best: (value: Double, trayIndex: Int, origin: Cell)?
        for i in 0..<3 {
            guard let piece = engine.state.tray[i] else { continue }
            let shape = piece.shape
            for r in 0...(Board.size - shape.height) {
                for c in 0...(Board.size - shape.width) {
                    let mask = shape.maskAt(row: r, col: c)
                    if occupancy & mask != 0 { continue }
                    let cleared = BitBoard.clearingFullLines(occupancy | mask)
                    let value = Self.evaluate(cleared.result) + 10 * Double(cleared.lines)
                    if best == nil || value > best!.value { best = (value, i, Cell(r, c)) }
                }
            }
        }
        return best.map { ($0.trayIndex, $0.origin) }
    }

    private static func evaluate(_ b: UInt64) -> Double {
        let col0: UInt64 = 0x0101_0101_0101_0101, row0: UInt64 = 0xFF
        let edges = ((b ^ (b >> 1)) & 0x7F7F_7F7F_7F7F_7F7F).nonzeroBitCount + ((b ^ (b >> 8)) & 0x00FF_FFFF_FFFF_FFFF).nonzeroBitCount
        let holes = (~b & ((b << 1) | col0) & ((b >> 1) | (col0 << 7)) & ((b << 8) | row0) & ((b >> 8) | (row0 << 56))).nonzeroBitCount
        return -Double(edges) - 0.7 * Double(b.nonzeroBitCount) - 3 * Double(holes)
    }
}

// MARK: - Independent (naive) solver

/// A deliberately simple, separately written solvability check: plain [Bool] grid, explicit row/column
/// scans, every permutation and every origin, no memo, no bit tricks. Used to cross-check `Solver` and
/// the generator, so a bug in the bitboard search cannot hide itself.
enum NaiveSolver {
    static func canPlaceAll(_ shapes: [Shape], on occupancy: UInt64) -> Bool {
        let grid = (0..<64).map { occupancy & (1 << UInt64($0)) != 0 }
        return solve(grid, Array(shapes.indices), shapes)
    }

    private static func solve(_ grid: [Bool], _ remaining: [Int], _ shapes: [Shape]) -> Bool {
        if remaining.isEmpty { return true }
        for (k, index) in remaining.enumerated() {
            let piece = shapes[index]
            var rest = remaining
            rest.remove(at: k)
            for r in 0...(8 - piece.height) {
                for c in 0...(8 - piece.width) {
                    if piece.cells.contains(where: { grid[(r + $0.row) * 8 + c + $0.col] }) { continue }
                    var next = grid
                    for cell in piece.cells { next[(r + cell.row) * 8 + c + cell.col] = true }
                    if solve(clearFullLines(next), rest, shapes) { return true }
                }
            }
        }
        return false
    }

    private static func clearFullLines(_ grid: [Bool]) -> [Bool] {
        var result = grid
        for r in 0..<8 where (0..<8).allSatisfy({ grid[r * 8 + $0] }) {
            for c in 0..<8 { result[r * 8 + c] = false }
        }
        for c in 0..<8 where (0..<8).allSatisfy({ grid[$0 * 8 + c] }) {
            for r in 0..<8 { result[r * 8 + c] = false }
        }
        return result
    }
}

// MARK: - Random positions

/// A random occupancy with exactly `fill` cells (8...56) and no full row/column, so it could occur in real
/// play. Sparse boards come from rejection sampling; dense ones start from one empty cell per row and
/// column (a permutation) and open further random cells, since random dense boards almost never qualify.
func randomStableOccupancy(fill: Int, rng: inout SeededRNG) -> UInt64 {
    precondition((8...56).contains(fill))
    func isStable(_ b: UInt64) -> Bool {
        let full = BitBoard.fullLines(b)
        return full.rows.isEmpty && full.cols.isEmpty
    }
    if fill <= 36 {
        while true {
            var b: UInt64 = 0
            while b.nonzeroBitCount < fill { b |= 1 << (rng.next() % 64) }
            if isStable(b) { return b }
        }
    }
    var perm = Array(0..<8)
    for i in stride(from: 7, to: 0, by: -1) { perm.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
    var b = UInt64.max
    for (r, c) in perm.enumerated() { b &= ~(1 << UInt64(r * 8 + c)) }
    while b.nonzeroBitCount > fill { b &= ~(1 << (rng.next() % 64)) }
    return b
}

/// Replays a deal's witness through the real `Board.place`, returning false at the first illegal step.
func witnessReplays(_ deal: Deal, on start: Board) -> Bool {
    guard deal.witness.count == 3, Set(deal.witness.map(\.slot)) == [0, 1, 2] else { return false }
    var b = start
    for step in deal.witness {
        let piece = deal.pieces[step.slot]
        guard b.canPlace(piece.shape, at: step.origin) else { return false }
        b.place(piece.shape, color: piece.color, at: step.origin)
    }
    return true
}
