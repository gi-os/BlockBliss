import XCTest
@testable import BlockEngine

final class BoardTests: XCTestCase {
    func testPlaceWithoutClear() {
        var b = Board()
        let result = b.place(shape("t_up"), color: .purple, at: Cell(2, 3))
        XCTAssertEqual(result.linesCleared, 0)
        XCTAssertTrue(result.clearedCells.isEmpty)
        XCTAssertEqual(Set(result.placedCells), [Cell(2, 3), Cell(2, 4), Cell(2, 5), Cell(3, 4)])
        XCTAssertEqual(b.filledCount, 4)
        XCTAssertEqual(b[2, 4], .purple)
        XCTAssertNil(b[3, 3])
    }

    func testCanPlaceChecksBoundsAndOverlap() {
        let b = Board(rows: rows(filled: [(0, 0)]))
        XCTAssertFalse(b.canPlace(shape("single"), at: Cell(0, 0)))
        XCTAssertTrue(b.canPlace(shape("single"), at: Cell(0, 1)))
        XCTAssertFalse(b.canPlace(shape("tri_h"), at: Cell(0, 6)))     // runs off the right edge
        XCTAssertFalse(b.canPlace(shape("tri_v"), at: Cell(6, 0)))     // runs off the bottom
        XCTAssertFalse(b.canPlace(shape("single"), at: Cell(-1, 0)))
        XCTAssertTrue(b.canPlace(shape("tri_h"), at: Cell(0, 5)))
        XCTAssertFalse(b.canPlace(shape("domino_v"), at: Cell(0, 0)))
    }

    func testRowClear() {
        var b = Board(rows: ["........", "........", "........", "........", "........", "........", "........", "XXXXXXX."] )
        b.place(shape("tri_h"), color: .red, at: Cell(0, 0))             // unrelated block that must survive
        let result = b.place(shape("single"), color: .green, at: Cell(7, 7))
        XCTAssertEqual(result.rows, [7])
        XCTAssertEqual(result.cols, [])
        XCTAssertEqual(result.clearedCells.count, 8)
        XCTAssertEqual(b.filledCount, 3)
        XCTAssertNil(b[7, 3])
        XCTAssertEqual(b[0, 1], .red)
    }

    func testColumnClear() {
        var rowsSpec = rows(filled: (1..<8).map { ($0, 4) })
        rowsSpec[0] = "X......."                                       // survivor
        var b = Board(rows: rowsSpec)
        let result = b.place(shape("single"), color: .cyan, at: Cell(0, 4))
        XCTAssertEqual(result.cols, [4])
        XCTAssertEqual(result.rows, [])
        XCTAssertEqual(result.clearedCells.count, 8)
        XCTAssertEqual(b.filledCount, 1)
        XCTAssertEqual(b[0, 0], .blue)
    }

    /// One placement completes a row and a column at the same time; the shared cell is cleared and counted once.
    func testSimultaneousRowAndColumnCountIntersectionOnce() {
        var cells = (0..<8).filter { $0 != 5 }.map { (3, $0) }          // row 3 minus (3,5)
        cells += (0..<8).filter { $0 != 3 }.map { ($0, 5) }             // column 5 minus (3,5)
        cells.append((0, 0))                                             // survivor
        var b = Board(rows: rows(filled: cells))
        let result = b.place(shape("single"), color: .orange, at: Cell(3, 5))
        XCTAssertEqual(result.rows, [3])
        XCTAssertEqual(result.cols, [5])
        XCTAssertEqual(result.linesCleared, 2)
        XCTAssertEqual(result.clearedCells.count, 15, "8 + 8 - 1 shared cell")
        XCTAssertEqual(Set(result.clearedCells.map(\.cell)).count, 15, "each cell reported once")
        XCTAssertTrue(result.clearedCells.contains { $0.cell == Cell(3, 5) && $0.color == .orange })
        XCTAssertEqual(b.filledCount, 1)
        XCTAssertEqual(b[0, 0], .blue)
        XCTAssertNil(b[3, 5])
    }

    func testTwoRowsAndTwoColumnsFromOnePiece() {
        // rows 0,1 and columns 0,1 each miss exactly the 2x2 square at the top-left corner
        var cells: [(Int, Int)] = []
        for r in 0..<2 { for c in 2..<8 { cells.append((r, c)) } }
        for r in 2..<8 { for c in 0..<2 { cells.append((r, c)) } }
        cells.append((7, 7))
        var b = Board(rows: rows(filled: cells))
        let result = b.place(shape("sq2"), color: .yellow, at: Cell(0, 0))
        XCTAssertEqual(result.rows, [0, 1])
        XCTAssertEqual(result.cols, [0, 1])
        XCTAssertEqual(result.linesCleared, 4)
        XCTAssertEqual(result.clearedCells.count, 16 + 16 - 4)
        XCTAssertEqual(b.filledCount, 1)
    }

    func testSixLinesIsTheMaximum() {
        var cells: [(Int, Int)] = []
        for r in 0..<3 { for c in 3..<8 { cells.append((r, c)) } }
        for r in 3..<8 { for c in 0..<3 { cells.append((r, c)) } }
        cells.append((7, 7))
        var b = Board(rows: rows(filled: cells))
        let result = b.place(shape("sq3"), color: .red, at: Cell(0, 0))
        XCTAssertEqual(result.linesCleared, 6)
        XCTAssertEqual(result.clearedCells.count, 3 * 8 + 3 * 8 - 9)
        XCTAssertEqual(b.filledCount, 1)
    }

    func testLinesCompletedPreviewMatchesPlacement() {
        let b = Board(rows: rows(filled: (0..<7).map { (7, $0) } + [(0, 0)]))
        XCTAssertEqual(b.linesCompleted(by: shape("single"), at: Cell(7, 7)).rows, [7])
        XCTAssertEqual(b.linesCompleted(by: shape("single"), at: Cell(6, 7)).rows, [])
        XCTAssertEqual(b.linesCompleted(by: shape("single"), at: Cell(0, 0)).rows, [], "invalid placement previews nothing")
    }

    func testBoardCodableKeepsOccupancyInSync() throws {
        var b = Board()
        b.place(shape("l4_c"), color: .green, at: Cell(4, 4))
        let decoded = try JSONDecoder().decode(Board.self, from: JSONEncoder().encode(b))
        XCTAssertEqual(decoded, b)
        XCTAssertEqual(decoded.occupancy, b.occupancy)
    }

    func testFastLineClearAgreesWithBitBoardReference() {
        var rng = SeededRNG(seed: 99)
        for i in 0..<5000 {
            var b = rng.next()
            if i % 2 == 0 { b |= BitBoard.rowMask(Int(rng.next() % 8)) }          // make full lines likely
            if i % 3 == 0 { b |= BitBoard.colMask(Int(rng.next() % 8)) }
            if i % 7 == 0 { b |= BitBoard.rowMask(Int(rng.next() % 8)) | BitBoard.colMask(Int(rng.next() % 8)) }
            let fast = BoardBits.clearFullLines(b)
            let reference = BitBoard.clearingFullLines(b)
            XCTAssertEqual(fast.board, reference.result)
            XCTAssertEqual(fast.lines, reference.lines)
        }
    }
}
