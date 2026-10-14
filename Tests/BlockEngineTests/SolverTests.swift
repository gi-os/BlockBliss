import XCTest
@testable import BlockEngine

final class SolverTests: XCTestCase {
    /// Replays a `Solver.solve` result through the real Board, returning false on the first illegal step.
    private func replay(_ shapes: [Shape], _ solution: [(shapeIndex: Int, origin: Cell)], on occupancy: UInt64) -> Bool {
        guard solution.count == shapes.count, Set(solution.map(\.shapeIndex)) == Set(shapes.indices) else { return false }
        var b = board(from: occupancy)
        for step in solution {
            let s = shapes[step.shapeIndex]
            guard b.canPlace(s, at: step.origin) else { return false }
            b.place(s, color: .red, at: step.origin)
        }
        return true
    }

    private func transposed(_ rows: [String]) -> [String] {
        (0..<8).map { c in String(rows.map { Array($0)[c] }) }
    }

    /// Every empty cell is isolated (no two share an edge) except that row 0 is one cell short of full.
    /// A domino fits nowhere until a single placed at (0,7) clears row 0.
    private let clearFirstRows = [
        "XXXXXXX.",
        "X.X.X.XX",
        ".X.X.X.X",
        "X.X.X.X.",
        ".X.X.X.X",
        "X.X.X.X.",
        ".X.X.X.X",
        "X.X.X.X.",
    ]
    private let checkerboard = ["X.X.X.X.", ".X.X.X.X", "X.X.X.X.", ".X.X.X.X", "X.X.X.X.", ".X.X.X.X", "X.X.X.X.", ".X.X.X.X"]

    // MARK: Hand-built positions

    func testEmptyListAndSinglePiecesOnEmptyBoard() {
        XCTAssertTrue(Solver.canPlaceAll([], on: 0))
        XCTAssertEqual(Solver.solve([], on: 0)?.count, 0)
        for s in ShapeCatalog.all {
            XCTAssertTrue(Solver.canPlaceAll([s], on: 0), s.id)
        }
    }

    func testAnyThreeCatalogPiecesFitOnAnEmptyBoard() {
        var rng = SeededRNG(seed: 1)
        for _ in 0..<500 {
            let shapes = (0..<3).map { _ in ShapeCatalog.all[Int(rng.next() % 41)] }
            let solution = Solver.solve(shapes, on: 0)
            XCTAssertNotNil(solution, shapes.map(\.id).joined(separator: ","))
            if let solution { XCTAssertTrue(replay(shapes, solution, on: 0)) }
        }
        let threeBigSquares = Array(repeating: shape("sq3"), count: 3)
        XCTAssertTrue(Solver.canPlaceAll(threeBigSquares, on: 0))
    }

    func testOnlyOneOrderWorksBecauseAClearIsNeeded() {
        let occupancy = Board(rows: clearFirstRows).occupancy
        let b = board(from: occupancy)
        XCTAssertFalse(b.hasAnyPlacement(for: shape("domino_h")), "precondition: the domino fits nowhere right now")
        XCTAssertFalse(b.hasAnyPlacement(for: shape("domino_v")))
        XCTAssertEqual(b.validOrigins(for: shape("single")).count, 28)

        // domino listed first: a solver that placed pieces in list order without clears would fail
        let shapes = [shape("domino_h"), shape("single")]
        XCTAssertTrue(Solver.canPlaceAll(shapes, on: occupancy))
        let solution = Solver.solve(shapes, on: occupancy)!
        XCTAssertEqual(solution.count, 2)
        XCTAssertEqual(solution[0].shapeIndex, 1, "the single must go first")
        XCTAssertEqual(solution[0].origin, Cell(0, 7), "and it must complete row 0")
        XCTAssertEqual(solution[1].shapeIndex, 0)
        XCTAssertTrue(replay(shapes, solution, on: occupancy))
        XCTAssertTrue(NaiveSolver.canPlaceAll(shapes, on: occupancy))

        // the reverse listing finds the same play
        let reversed = Solver.solve([shape("single"), shape("domino_h")], on: occupancy)!
        XCTAssertEqual(reversed[0].shapeIndex, 0)
        XCTAssertEqual(reversed[0].origin, Cell(0, 7))
    }

    func testClearFirstAlsoWorksForColumns() {
        let rows = transposed(clearFirstRows)
        let occupancy = Board(rows: rows).occupancy
        let shapes = [shape("domino_v"), shape("tri_v"), shape("single")]
        XCTAssertFalse(board(from: occupancy).hasAnyPlacement(for: shape("domino_v")))
        let solution = Solver.solve(shapes, on: occupancy)
        XCTAssertNotNil(solution)
        XCTAssertEqual(solution?.first?.shapeIndex, 2)
        XCTAssertEqual(solution?.first?.origin, Cell(7, 0))
        if let solution { XCTAssertTrue(replay(shapes, solution, on: occupancy)) }
    }

    func testClearFreesRoomForTwoPieces() {
        // single clears row 0 -> a tri and a domino both fit in the freed row (3 + 2 = 5 cells of 8)
        let occupancy = Board(rows: clearFirstRows).occupancy
        let shapes = [shape("tri_h"), shape("domino_h"), shape("single")]
        let solution = Solver.solve(shapes, on: occupancy)
        XCTAssertNotNil(solution)
        if let solution {
            XCTAssertEqual(solution[0].shapeIndex, 2)
            XCTAssertTrue(replay(shapes, solution, on: occupancy))
        }
    }

    func testUnsolvableWhenNothingCanClearAndPiecesDoNotFit() {
        let occupancy = Board(rows: checkerboard).occupancy
        for shapes in [[shape("domino_h")], [shape("sq3")], [shape("single"), shape("domino_v")],
                       [shape("tri_h"), shape("single"), shape("single")], [shape("diag3_main"), shape("tri_v")]] {
            XCTAssertFalse(Solver.canPlaceAll(shapes, on: occupancy), shapes.map(\.id).joined(separator: ","))
            XCTAssertNil(Solver.solve(shapes, on: occupancy))
            XCTAssertFalse(NaiveSolver.canPlaceAll(shapes, on: occupancy))
        }
        // pieces that do fit the isolated holes are fine
        let fits = [shape("single"), shape("single"), shape("diag2_main")]
        XCTAssertTrue(Solver.canPlaceAll(fits, on: occupancy))
        XCTAssertTrue(NaiveSolver.canPlaceAll(fits, on: occupancy))
        XCTAssertTrue(Solver.canPlaceAll([shape("single"), shape("single"), shape("single")], on: occupancy))
    }

    func testIdenticalShapesAreHandled() {
        let occupancy = Board(rows: checkerboard).occupancy
        let singles = Array(repeating: shape("single"), count: 3)
        let solution = Solver.solve(singles, on: occupancy)
        XCTAssertNotNil(solution)
        if let solution { XCTAssertTrue(replay(singles, solution, on: occupancy)) }
        let dominoes = Array(repeating: shape("domino_h"), count: 3)
        XCTAssertTrue(Solver.canPlaceAll(dominoes, on: 0))
        XCTAssertFalse(Solver.canPlaceAll(dominoes, on: occupancy))
    }

    func testCapReachedMeansNotProven() {
        var search = TraySearch([ShapeCatalog.placements(for: shape("single"))], nodeCap: 0)
        XCTAssertFalse(search.run(on: 0))
        XCTAssertTrue(search.aborted)

        var uncapped = TraySearch([ShapeCatalog.placements(for: shape("single"))], nodeCap: .max)
        XCTAssertTrue(uncapped.run(on: 0))
        XCTAssertFalse(uncapped.aborted)
        XCTAssertEqual(uncapped.witness.count, 1)
    }

    func testSearchCanBeReloadedForAnotherTray() {
        var search = TraySearch()
        let occupancy = Board(rows: clearFirstRows).occupancy
        search.load([ShapeCatalog.placements(for: shape("domino_h"))], nodeCap: .max)
        XCTAssertFalse(search.run(on: occupancy))
        search.load([ShapeCatalog.placements(for: shape("single")), ShapeCatalog.placements(for: shape("domino_h"))], nodeCap: .max)
        XCTAssertTrue(search.run(on: occupancy))
        XCTAssertEqual(search.witness.first?.slot, 0)
        search.load([ShapeCatalog.placements(for: shape("domino_h"))], nodeCap: .max)
        XCTAssertFalse(search.run(on: occupancy), "memo from the previous tray must not leak")
    }

    // MARK: Cross-check against the naive solver

    func testMatchesNaiveSolverOnRandomPositions() {
        var rng = SeededRNG(seed: 20_260_101)
        var solvable = 0, unsolvable = 0
        for i in 0..<700 {
            let fill = 26 + Int(rng.next() % 36)                                  // 26...61 cells
            var occupancy: UInt64 = 0
            while occupancy.nonzeroBitCount < fill { occupancy |= 1 << (rng.next() % 64) }
            let count = 1 + Int(rng.next() % 3)
            let shapes = (0..<count).map { _ in ShapeCatalog.all[Int(rng.next() % 41)] }
            let expected = NaiveSolver.canPlaceAll(shapes, on: occupancy)
            let solution = Solver.solve(shapes, on: occupancy)
            XCTAssertEqual(Solver.canPlaceAll(shapes, on: occupancy), expected, "case \(i): \(shapes.map(\.id))")
            XCTAssertEqual(solution != nil, expected, "case \(i)")
            if let solution { XCTAssertTrue(replay(shapes, solution, on: occupancy), "case \(i) witness") }
            if expected { solvable += 1 } else { unsolvable += 1 }
        }
        XCTAssertGreaterThan(solvable, 100, "sample must contain solvable positions")
        XCTAssertGreaterThan(unsolvable, 100, "sample must contain unsolvable positions")
    }

    func testMatchesNaiveSolverWhenClearsDecideTheAnswer() {
        // Near-full stable-ish boards where a placement usually completes a line.
        var rng = SeededRNG(seed: 555)
        var decidedByClear = 0
        for _ in 0..<500 {
            var occupancy = UInt64.max
            // knock out a handful of cells, keeping one hole per row so no line is full
            for r in 0..<8 { occupancy &= ~(1 << UInt64(r * 8 + Int(rng.next() % 8))) }
            for _ in 0..<Int(rng.next() % 5) { occupancy &= ~(1 << (rng.next() % 64)) }
            let shapes = (0..<3).map { _ in ShapeCatalog.all[Int(rng.next() % 41)] }
            let expected = NaiveSolver.canPlaceAll(shapes, on: occupancy)
            XCTAssertEqual(Solver.canPlaceAll(shapes, on: occupancy), expected)
            let b = board(from: occupancy)
            if expected, shapes.contains(where: { !b.hasAnyPlacement(for: $0) }) { decidedByClear += 1 }
        }
        XCTAssertGreaterThan(decidedByClear, 5, "some answers must genuinely depend on clears")
    }
}
