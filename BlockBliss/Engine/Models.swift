import Foundation

// MARK: - Basic types

/// A board coordinate. Row 0 is the top row, col 0 the left column.
public struct Cell: Hashable, Codable, Sendable, CustomStringConvertible {
    public var row: Int
    public var col: Int

    public init(row: Int, col: Int) {
        self.row = row
        self.col = col
    }

    public init(_ row: Int, _ col: Int) {
        self.init(row: row, col: col)
    }

    /// Bit index of this cell in a row-major 8x8 bitboard.
    @inlinable public var bit: Int { row * Board.size + col }

    public var description: String { "(\(row),\(col))" }
}

/// The seven block colours of the default skin. The UI maps these to actual colours.
public enum BlockColor: Int, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, cyan, blue, purple
}

// MARK: - Bitboard helpers

/// 8x8 occupancy stored row-major in a UInt64: bit (row * 8 + col).
public enum BitBoard {
    @inlinable public static func rowMask(_ row: Int) -> UInt64 { 0xFF << UInt64(row * 8) }
    @inlinable public static func colMask(_ col: Int) -> UInt64 { 0x0101_0101_0101_0101 << UInt64(col) }

    public static let rowMasks: [UInt64] = (0..<8).map(rowMask)
    public static let colMasks: [UInt64] = (0..<8).map(colMask)

    /// Rows and columns that are completely filled in `occupancy`.
    @inlinable public static func fullLines(_ occupancy: UInt64) -> (rows: [Int], cols: [Int]) {
        var rows: [Int] = []
        var cols: [Int] = []
        for i in 0..<8 {
            if occupancy & rowMasks[i] == rowMasks[i] { rows.append(i) }
            if occupancy & colMasks[i] == colMasks[i] { cols.append(i) }
        }
        return (rows, cols)
    }

    /// Occupancy after removing every full row and column (rows and columns clear simultaneously).
    @inlinable public static func clearingFullLines(_ occupancy: UInt64) -> (result: UInt64, lines: Int) {
        var clearMask: UInt64 = 0
        var lines = 0
        for i in 0..<8 {
            let r = rowMasks[i]
            if occupancy & r == r { clearMask |= r; lines += 1 }
            let c = colMasks[i]
            if occupancy & c == c { clearMask |= c; lines += 1 }
        }
        return (occupancy & ~clearMask, lines)
    }
}

// MARK: - Shapes and pieces

/// Families group orientations of the same polyomino; used for weights and stats.
public enum PieceFamily: String, Codable, CaseIterable, Sendable {
    case single        // 1x1
    case line2         // 1x2 / 2x1
    case line3         // 1x3 / 3x1
    case line4         // 1x4 / 4x1
    case line5         // 1x5 / 5x1
    case square2       // 2x2
    case square3       // 3x3
    case rect2x3       // 2x3 / 3x2
    case corner3       // 3-cell small L
    case lShape4       // 4-cell L / J
    case corner5       // 5-cell big L (3x3 corner)
    case tShape        // T
    case sShape        // S / Z
    case diagonal2     // 2 cells touching at a corner
    case diagonal3     // 3 cells on a diagonal
}

/// One fixed orientation of a piece. Pieces never rotate, so every orientation is its own shape.
public struct Shape: Hashable, Codable, Sendable, Identifiable {
    /// Stable identifier, e.g. "line5.h", "lShape4.3". Used for persistence.
    public let id: String
    public let family: PieceFamily
    /// Cells normalised so the minimum row and minimum col are 0.
    public let cells: [Cell]
    public let width: Int
    public let height: Int
    /// Bitboard of the shape placed at origin (0, 0).
    public let mask: UInt64

    public init(id: String, family: PieceFamily, cells: [Cell]) {
        let minR = cells.map(\.row).min() ?? 0
        let minC = cells.map(\.col).min() ?? 0
        let norm = cells.map { Cell(row: $0.row - minR, col: $0.col - minC) }
            .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        self.id = id
        self.family = family
        self.cells = norm
        self.width = (norm.map(\.col).max() ?? 0) + 1
        self.height = (norm.map(\.row).max() ?? 0) + 1
        self.mask = norm.reduce(UInt64(0)) { $0 | (1 << UInt64($1.bit)) }
    }

    /// Convenience: build from an ASCII picture, "X" = filled, "." = empty, rows separated by "/".
    /// Example: `Shape(id: "tShape.0", family: .tShape, pattern: "XXX/.X.")`
    public init(id: String, family: PieceFamily, pattern: String) {
        var cells: [Cell] = []
        for (r, line) in pattern.split(separator: "/").enumerated() {
            for (c, ch) in line.enumerated() where ch == "X" { cells.append(Cell(r, c)) }
        }
        self.init(id: id, family: family, cells: cells)
    }

    public var cellCount: Int { cells.count }

    /// Valid top-left origins range: row in 0...(8-height), col in 0...(8-width).
    @inlinable public func maskAt(row: Int, col: Int) -> UInt64 { mask << UInt64(row * Board.size + col) }

    @inlinable public func fitsInBounds(row: Int, col: Int) -> Bool {
        row >= 0 && col >= 0 && row + height <= Board.size && col + width <= Board.size
    }

    public static func == (lhs: Shape, rhs: Shape) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A piece instance dealt into the tray: a shape plus a colour. `id` is unique per deal (for SwiftUI identity).
public struct Piece: Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let shape: Shape
    public let color: BlockColor

    public init(id: UUID = UUID(), shape: Shape, color: BlockColor) {
        self.id = id
        self.shape = shape
        self.color = color
    }
}

// MARK: - Board

/// The 8x8 board. `colors` is the source of truth; `occupancy` mirrors it as a bitboard.
public struct Board: Codable, Equatable, Sendable {
    public static let size = 8
    public static let cellCount = 64

    public private(set) var colors: [BlockColor?]
    public private(set) var occupancy: UInt64

    public init() {
        colors = Array(repeating: nil, count: Board.cellCount)
        occupancy = 0
    }

    public subscript(row: Int, col: Int) -> BlockColor? {
        colors[row * Board.size + col]
    }

    public subscript(cell: Cell) -> BlockColor? {
        colors[cell.bit]
    }

    public var isEmpty: Bool { occupancy == 0 }
    public var filledCount: Int { occupancy.nonzeroBitCount }

    // MARK: Queries

    public func canPlace(_ shape: Shape, at origin: Cell) -> Bool {
        guard shape.fitsInBounds(row: origin.row, col: origin.col) else { return false }
        return occupancy & shape.maskAt(row: origin.row, col: origin.col) == 0
    }

    /// Every origin where `shape` fits right now.
    public func validOrigins(for shape: Shape) -> [Cell] {
        var result: [Cell] = []
        for r in 0...(Board.size - shape.height) {
            for c in 0...(Board.size - shape.width) where occupancy & shape.maskAt(row: r, col: c) == 0 {
                result.append(Cell(r, c))
            }
        }
        return result
    }

    public func hasAnyPlacement(for shape: Shape) -> Bool {
        for r in 0...(Board.size - shape.height) {
            for c in 0...(Board.size - shape.width) where occupancy & shape.maskAt(row: r, col: c) == 0 {
                return true
            }
        }
        return false
    }

    /// Rows/cols that would be cleared if `shape` were placed at `origin`. Empty if placement is invalid.
    public func linesCompleted(by shape: Shape, at origin: Cell) -> (rows: [Int], cols: [Int]) {
        guard canPlace(shape, at: origin) else { return ([], []) }
        return BitBoard.fullLines(occupancy | shape.maskAt(row: origin.row, col: origin.col))
    }

    // MARK: Mutation

    /// Places the shape (caller must have checked `canPlace`), then clears every completed row and
    /// column simultaneously. Returns what was cleared so the UI can animate it.
    @discardableResult
    public mutating func place(_ shape: Shape, color: BlockColor, at origin: Cell) -> ClearResult {
        precondition(canPlace(shape, at: origin), "invalid placement of \(shape.id) at \(origin)")
        var placed: [Cell] = []
        for cell in shape.cells {
            let target = Cell(row: origin.row + cell.row, col: origin.col + cell.col)
            colors[target.bit] = color
            placed.append(target)
        }
        occupancy |= shape.maskAt(row: origin.row, col: origin.col)

        let (rows, cols) = BitBoard.fullLines(occupancy)
        var cleared: [ClearedCell] = []
        var clearMask: UInt64 = 0
        for r in rows { clearMask |= BitBoard.rowMask(r) }
        for c in cols { clearMask |= BitBoard.colMask(c) }
        if clearMask != 0 {
            for bit in 0..<Board.cellCount where clearMask & (1 << UInt64(bit)) != 0 {
                if let color = colors[bit] {
                    cleared.append(ClearedCell(cell: Cell(row: bit / Board.size, col: bit % Board.size), color: color))
                }
                colors[bit] = nil
            }
            occupancy &= ~clearMask
        }
        return ClearResult(placedCells: placed, rows: rows, cols: cols, clearedCells: cleared)
    }

    /// Test/debug helper: build a board from 8 strings of "X"/"." (X = filled, colour defaults to blue).
    public init(rows: [String], color: BlockColor = .blue) {
        self.init()
        for (r, line) in rows.prefix(Board.size).enumerated() {
            for (c, ch) in line.prefix(Board.size).enumerated() where ch != "." && ch != " " {
                colors[r * Board.size + c] = color
                occupancy |= 1 << UInt64(r * Board.size + c)
            }
        }
    }

    // Keep occupancy derived on decode so a corrupted save can't desync the two.
    private enum CodingKeys: String, CodingKey { case colors }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decoded = try container.decode([BlockColor?].self, forKey: .colors)
        if decoded.count != Board.cellCount { decoded = Array(repeating: nil, count: Board.cellCount) }
        colors = decoded
        occupancy = decoded.enumerated().reduce(UInt64(0)) { $1.element == nil ? $0 : $0 | (1 << UInt64($1.offset)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colors, forKey: .colors)
    }
}

public struct ClearedCell: Hashable, Codable, Sendable {
    public let cell: Cell
    public let color: BlockColor
}

public struct ClearResult: Equatable, Sendable {
    public let placedCells: [Cell]
    public let rows: [Int]
    public let cols: [Int]
    /// Every cell removed by the clear, with the colour it had (includes just-placed cells).
    public let clearedCells: [ClearedCell]

    public var linesCleared: Int { rows.count + cols.count }
}

// MARK: - Seeded RNG

/// SplitMix64: tiny, fast, good-quality, and its whole state is one UInt64 so it persists trivially.
public struct SeededRNG: RandomNumberGenerator, Codable, Equatable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in [0, 1).
    public mutating func nextUnit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
