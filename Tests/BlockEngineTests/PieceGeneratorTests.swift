import XCTest
@testable import BlockEngine

final class PieceGeneratorTests: XCTestCase {
    // MARK: Helpers

    private func ids(_ deal: Deal) -> [String] { deal.pieces.map(\.shape.id) }

    private func deal(on occupancy: UInt64, score: Int = 0, round: Int = 0, history: [[String]] = [],
                      seed: UInt64) -> (deal: Deal, board: Board) {
        var rng = SeededRNG(seed: seed), colorRNG = SeededRNG(seed: seed ^ 0xFEED)
        let b = board(from: occupancy)
        return (PieceGenerator.deal(board: b, score: score, round: round, history: history, rng: &rng, colorRNG: &colorRNG), b)
    }

    /// Every way the tray could be wrong: proven placeable by an independent solver, by the exact solver, and
    /// by replaying the witness through `Board.place`.
    private func assertSolvable(_ d: Deal, on b: Board, _ message: @autoclosure () -> String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(d.pieces.count, 3, message(), file: file, line: line)
        let shapes = d.pieces.map(\.shape)
        XCTAssertTrue(NaiveSolver.canPlaceAll(shapes, on: b.occupancy), "naive solver: \(message())", file: file, line: line)
        XCTAssertTrue(Solver.canPlaceAll(shapes, on: b.occupancy), "exact solver: \(message())", file: file, line: line)
        XCTAssertTrue(witnessReplays(d, on: b), "witness: \(message())", file: file, line: line)
        XCTAssertTrue((0...4).contains(d.fallbackLevel), message(), file: file, line: line)
    }

    private func style(forSeed seed: UInt64) -> Mover.Style {
        switch seed % 5 { case 0: return .random; case 1: return .lineSeeking; default: return .greedy }
    }

    /// Plays games through the real engine and hands `body` every position right after a tray was dealt
    /// (including the first), with the engine's own tray in `state`.
    private func forEachDealtState(games: Range<UInt64>, maxMoves: Int, _ body: (GameState) -> Void) {
        for seed in games {
            var engine = GameEngine(seed: seed)
            var mover = Mover(seed: seed ^ 0x5EED, style: style(forSeed: seed))
            body(engine.state)
            for _ in 0..<maxMoves where !engine.state.isGameOver {
                guard let move = mover.next(engine) else { break }
                if engine.place(trayIndex: move.trayIndex, at: move.origin)!.newTrayDealt { body(engine.state) }
            }
        }
    }

    /// Like `forEachDealtState`, but replays each deal through `PieceGenerator.deal` with the exact inputs the
    /// engine used, so the `Deal` (witness, fallback level) can be inspected and the engine's tray cross-checked.
    private func forEachReplayedDeal(games: Range<UInt64>, maxMoves: Int,
                                     _ check: (_ deal: Deal, _ state: GameState, _ round: Int, _ history: [[String]]) -> Void) {
        for seed in games {
            var engine = GameEngine(seed: seed)
            var mover = Mover(seed: seed ^ 0x5EED, style: style(forSeed: seed))
            let initial = GameState(seed: seed)
            replay(engine.state, history: [], rng: initial.rng, colorRNG: initial.colorRNG, check)
            for _ in 0..<maxMoves where !engine.state.isGameOver {
                guard let move = mover.next(engine) else { break }
                let rng = engine.state.rng, colorRNG = engine.state.colorRNG, history = engine.state.trayHistory
                if engine.place(trayIndex: move.trayIndex, at: move.origin)!.newTrayDealt {
                    replay(engine.state, history: history, rng: rng, colorRNG: colorRNG, check)
                }
            }
        }
    }

    private func replay(_ state: GameState, history: [[String]], rng: SeededRNG, colorRNG: SeededRNG,
                        _ check: (Deal, GameState, Int, [[String]]) -> Void) {
        var rng = rng, colorRNG = colorRNG
        let round = state.round - 1
        let again = PieceGenerator.deal(board: state.board, score: state.score, round: round, history: history,
                                        rng: &rng, colorRNG: &colorRNG)
        // the replay must reproduce what the engine dealt (shape and colour; ids are fresh UUIDs)
        XCTAssertEqual(again.pieces.map(\.shape.id), state.tray.compactMap { $0?.shape.id })
        XCTAssertEqual(again.pieces.map(\.color), state.tray.compactMap { $0?.color })
        XCTAssertEqual(rng, state.rng)
        XCTAssertEqual(colorRNG, state.colorRNG)
        check(again, state, round, history)
    }

    // MARK: Soundness (the fairness promise)

    func testEveryDealOnReachableBoardsIsSolvable() {
        var deals = 0
        var firstGame: UInt64 = 0
        // keep playing batches of games until we have thousands of real, reachable boards
        while deals < 3000 && firstGame < 400 {
            forEachDealtState(games: firstGame..<(firstGame + 10), maxMoves: 700) { state in
                deals += 1
                let shapes = state.tray.compactMap { $0?.shape }
                XCTAssertEqual(shapes.count, 3)
                XCTAssertTrue(NaiveSolver.canPlaceAll(shapes, on: state.board.occupancy),
                              "naive solver: seed \(state.seed) round \(state.round)")
                XCTAssertTrue(Solver.canPlaceAll(shapes, on: state.board.occupancy), "seed \(state.seed) round \(state.round)")
                // Lemma A: reachable boards have no full line and at least 8 empty cells
                let full = BitBoard.fullLines(state.board.occupancy)
                XCTAssertTrue(full.rows.isEmpty && full.cols.isEmpty)
                XCTAssertLessThanOrEqual(state.board.filledCount, 56)
            }
            firstGame += 10
        }
        XCTAssertGreaterThanOrEqual(deals, 3000, "needs thousands of deals to mean anything")
    }

    func testDealWitnessesReplayAndEngineDealsAreReproducible() {
        var deals = 0
        var levels = [Int](repeating: 0, count: 5)
        forEachReplayedDeal(games: 0..<20, maxMoves: 200) { deal, state, round, _ in
            deals += 1
            levels[deal.fallbackLevel] += 1
            self.assertSolvable(deal, on: state.board, "seed \(state.seed) round \(round)")
        }
        XCTAssertGreaterThan(deals, 500)
        XCTAssertGreaterThan(levels[0], deals * 9 / 10, "normal dealing should dominate: \(levels)")
    }

    func testEveryDealOnRandomStableBoardsIsSolvable() {
        var rng = SeededRNG(seed: 123)
        var levels = [Int](repeating: 0, count: 5)
        var hardEnd = 0
        for i in 0..<1500 {
            let fill = 8 + Int(rng.next() % 49)                        // 8...56 filled
            let occupancy = randomStableOccupancy(fill: fill, rng: &rng)
            let score = Int(rng.next() % 30_000), round = Int(rng.next() % 220)
            let (d, b) = deal(on: occupancy, score: score, round: round, seed: UInt64(i))
            levels[d.fallbackLevel] += 1
            if PieceGenerator.difficulty(score: score, round: round) > 0.8 { hardEnd += 1 }
            assertSolvable(d, on: b, "fill \(fill) score \(score) round \(round) seed \(i)")
        }
        XCTAssertGreaterThan(levels[0], 900, "\(levels)")
        XCTAssertGreaterThan(hardEnd, 300, "the ramp's hard end must be covered too")
    }

    /// 8 empty cells, one per row and column, none touching: only 1x1s fit without a clear.
    private func permutationBoard(_ rng: inout SeededRNG) -> UInt64 {
        while true {
            var perm = Array(0..<8)
            for i in stride(from: 7, to: 0, by: -1) { perm.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            guard (0..<7).allSatisfy({ abs(perm[$0] - perm[$0 + 1]) >= 2 }) else { continue }
            let empties = perm.enumerated().reduce(UInt64(0)) { $0 | (1 << UInt64($1.offset * 8 + $1.element)) }
            return ~empties
        }
    }

    func testAdversarialPermutationBoardsStillGetVerifiedTrays() {
        var rng = SeededRNG(seed: 77)
        var levels = [Int](repeating: 0, count: 5)
        for i in 0..<300 {
            let occupancy = permutationBoard(&rng)
            XCTAssertEqual(occupancy.nonzeroBitCount, 56)
            let (d, b) = deal(on: occupancy, score: i * 40, round: i % 150, seed: UInt64(1000 + i))
            levels[d.fallbackLevel] += 1
            assertSolvable(d, on: b, "permutation board \(i)")
            if d.fallbackLevel == 4 { XCTAssertEqual(ids(d), ["single", "single", "single"]) }
        }
        XCTAssertGreaterThan(levels[2] + levels[3] + levels[4], 0, "the fallback ladder must actually be exercised: \(levels)")
    }

    func testThreeSinglesIsTheLastResortAndAlwaysValid() {
        // Even a board with only 8 empty cells accepts three singles (Lemma B).
        var rng = SeededRNG(seed: 5)
        for _ in 0..<200 {
            let occupancy = permutationBoard(&rng)
            let singles = Array(repeating: shape("single"), count: 3)
            XCTAssertTrue(Solver.canPlaceAll(singles, on: occupancy))
            XCTAssertTrue(NaiveSolver.canPlaceAll(singles, on: occupancy))
        }
    }

    func testFirstDealOnAnEmptyBoardIsNormalAndGenerous() {
        var cells = 0
        var heavyTrays = 0
        for seed in UInt64(0)..<200 {
            let (d, b) = deal(on: 0, seed: seed)
            assertSolvable(d, on: b)
            XCTAssertEqual(d.fallbackLevel, 0)
            cells += d.pieces.reduce(0) { $0 + $1.shape.cellCount }
            let heavy = d.pieces.filter { $0.shape.cellCount >= 5 }.count
            XCTAssertLessThanOrEqual(heavy, 1, "at most one heavy piece in an opening tray: \(ids(d))")
            if heavy > 0 { heavyTrays += 1 }
        }
        let averageTray = Double(cells) / 200
        XCTAssertLessThan(averageTray, 11.5, "opening trays are small")
        XCTAssertGreaterThan(averageTray, 8)
        XCTAssertGreaterThan(heavyTrays, 0)
    }

    // MARK: Determinism and purity

    func testSameInputsSameDeal() {
        let occupancy = Board(rows: ["XX......", "XX..XX..", "........", "...XXX..", "........", "........", "X.......", "X.X....."]).occupancy
        let a = deal(on: occupancy, score: 900, round: 14, history: [["sq2", "tri_h", "single"], ["l4_a", "t_up", "z_h"]], seed: 31)
        let b = deal(on: occupancy, score: 900, round: 14, history: [["sq2", "tri_h", "single"], ["l4_a", "t_up", "z_h"]], seed: 31)
        XCTAssertEqual(ids(a.deal), ids(b.deal))
        XCTAssertEqual(a.deal.pieces.map(\.color), b.deal.pieces.map(\.color))
        XCTAssertEqual(a.deal.fallbackLevel, b.deal.fallbackLevel)
        XCTAssertEqual(a.deal.nodesSearched, b.deal.nodesSearched)
        XCTAssertEqual(a.deal.witness.map(\.slot), b.deal.witness.map(\.slot))
        XCTAssertEqual(a.deal.witness.map(\.origin), b.deal.witness.map(\.origin))
    }

    func testDifferentSeedsGiveDifferentDeals() {
        var seen = Set<[String]>()
        for seed in UInt64(0)..<30 { seen.insert(ids(deal(on: 0, seed: seed).deal)) }
        XCTAssertGreaterThan(seen.count, 20)
    }

    func testDealsAdvanceBothRNGStreams() {
        var rng = SeededRNG(seed: 1), colorRNG = SeededRNG(seed: 2)
        let before = (rng, colorRNG)
        _ = PieceGenerator.deal(board: Board(), score: 0, round: 0, history: [], rng: &rng, colorRNG: &colorRNG)
        XCTAssertNotEqual(rng, before.0)
        XCTAssertNotEqual(colorRNG, before.1)
    }

    func testWholeRunsReproduceFromTheSeed() {
        func trays(_ seed: UInt64) -> [[String]] {
            var out: [[String]] = []
            forEachReplayedDeal(games: seed..<(seed + 1), maxMoves: 150) { deal, _, _, _ in out.append(deal.pieces.map(\.shape.id)) }
            return out
        }
        XCTAssertEqual(trays(8), trays(8))
        XCTAssertNotEqual(trays(8), trays(9))
    }

    // MARK: Colours

    func testColoursAreDistinctWithinATrayAndIndependentOfShapes() {
        var seen = Set<BlockColor>()
        for seed in UInt64(0)..<120 {
            let (d, _) = deal(on: 0, seed: seed)
            let colors = d.pieces.map(\.color)
            XCTAssertEqual(Set(colors).count, 3, "no repeated colour in one tray")
            seen.formUnion(colors)
        }
        XCTAssertEqual(seen, Set(BlockColor.allCases), "all seven colours appear")

        // changing only the colour stream changes colours but never shapes, and shape RNG state is untouched
        var rngA = SeededRNG(seed: 9), rngB = SeededRNG(seed: 9)
        var colorA = SeededRNG(seed: 1), colorB = SeededRNG(seed: 2)
        let a = PieceGenerator.deal(board: Board(), score: 0, round: 0, history: [], rng: &rngA, colorRNG: &colorA)
        let b = PieceGenerator.deal(board: Board(), score: 0, round: 0, history: [], rng: &rngB, colorRNG: &colorB)
        XCTAssertEqual(ids(a), ids(b))
        XCTAssertEqual(rngA, rngB)
        XCTAssertNotEqual(a.pieces.map(\.color), b.pieces.map(\.color))
    }

    func testColourStreamIsConsumedUniformlyThreeDrawsPerDeal() {
        // same number of colour draws whichever fallback level produced the tray
        var rng = SeededRNG(seed: 4)
        for i in 0..<60 {
            let occupancy = i % 2 == 0 ? permutationBoard(&rng) : 0
            var colorRNG = SeededRNG(seed: 99), shapeRNG = SeededRNG(seed: UInt64(i))
            _ = PieceGenerator.deal(board: board(from: occupancy), score: 0, round: 0, history: [], rng: &shapeRNG, colorRNG: &colorRNG)
            var expected = SeededRNG(seed: 99)
            for _ in 0..<3 { _ = expected.next() }
            XCTAssertEqual(colorRNG, expected)
        }
    }

    // MARK: Tray rules at the normal level

    func testNormalTraysObeyFamilyHeavyAndRepetitionRules() {
        var checked = 0
        var previousKey: [String]?
        var currentSeed: UInt64 = .max
        forEachReplayedDeal(games: 0..<24, maxMoves: 200) { deal, state, round, history in
            if state.seed != currentSeed { currentSeed = state.seed; previousKey = nil }
            defer { previousKey = self.ids(deal).sorted() }
            guard deal.fallbackLevel == 0 else { return }
            checked += 1
            let d = PieceGenerator.difficulty(score: state.score, round: round)
            let shapes = deal.pieces.map(\.shape)
            let familyCounts = Dictionary(grouping: shapes, by: \.family).mapValues(\.count)
            XCTAssertLessThanOrEqual(familyCounts.values.max() ?? 0, 2, "no three of one family at level 0: \(self.ids(deal))")
            let heavy = shapes.filter { $0.cellCount >= 5 }.count
            XCTAssertLessThanOrEqual(heavy, d < 0.25 ? 1 : (d < 0.9 ? 2 : 3), "heavy cap at d=\(d): \(self.ids(deal))")
            XCTAssertLessThanOrEqual(shapes.filter { $0.family == .square3 }.count, d < 0.8 ? 1 : 2)
            if let previousKey { XCTAssertNotEqual(self.ids(deal).sorted(), previousKey, "same tray twice in a row") }
            XCTAssertLessThan(deal.nodesSearched, 40_000)
        }
        XCTAssertGreaterThan(checked, 600)
    }

    func testRecentTraysAreDownWeighted() {
        let history = [["l4_a", "t_up", "z_h"], ["sq2", "tri_h", "corner_nw"]]
        let recent = Set(history[1])
        func hits(_ history: [[String]]) -> Int {
            var n = 0
            for seed in UInt64(0)..<700 {
                n += ids(deal(on: 0, round: 120, history: history, seed: seed).deal).filter { recent.contains($0) }.count
            }
            return n
        }
        let withHistory = hits(history), without = hits([])
        XCTAssertLessThan(Double(withHistory), 0.85 * Double(without), "last tray's shapes should come up less often: \(withHistory) vs \(without)")
    }

    // MARK: Difficulty ramp and weights

    func testDifficultyRampShape() {
        XCTAssertEqual(PieceGenerator.difficulty(score: 0, round: 0), 0)
        // the ramp passes exactly through its documented anchors (see Tuning.progressAnchors / the tuning log)
        for (progress, d) in PieceGenerator.Tuning.progressAnchors {
            XCTAssertEqual(PieceGenerator.difficulty(score: 0, round: Int(progress)), d, accuracy: 1e-9, "round \(progress)")
        }
        // whatever the tuning, the opening is generous and the ramp finishes in a sensible time
        XCTAssertLessThanOrEqual(PieceGenerator.difficulty(score: 0, round: 10), 0.2)
        XCTAssertLessThan(PieceGenerator.difficulty(score: 0, round: 20), 0.4)
        XCTAssertEqual(PieceGenerator.difficulty(score: 0, round: 150), 1.0, accuracy: 1e-9)
        XCTAssertEqual(PieceGenerator.difficulty(score: 0, round: 10_000), 1.0)
        XCTAssertEqual(PieceGenerator.difficulty(score: -50, round: -3), 0)

        var last = 0.0
        for round in 0...200 {
            let d = PieceGenerator.difficulty(score: 0, round: round)
            XCTAssertGreaterThanOrEqual(d, last)
            XCTAssertTrue((0.0...1.0).contains(d))
            last = d
        }
        last = 0
        for score in stride(from: 0, through: 40_000, by: 250) {
            let d = PieceGenerator.difficulty(score: score, round: 5)
            XCTAssertGreaterThanOrEqual(d, last)
            last = d
        }
    }

    func testScoreOnlyAcceleratesTheRamp() {
        // a strong run (lots of score early) is never dealt an easier ramp than rounds alone give
        for round in stride(from: 0, to: 200, by: 7) {
            for score in stride(from: 0, to: 30_000, by: 1_500) {
                XCTAssertGreaterThanOrEqual(PieceGenerator.difficulty(score: score, round: round),
                                            PieceGenerator.difficulty(score: 0, round: round))
            }
        }
        XCTAssertEqual(PieceGenerator.difficulty(score: 10_000_000, round: 0), 1.0)
    }

    func testWeightsRampTowardsHeavyAwkwardPieces() {
        func stats(_ d: Double) -> (avgCells: Double, heavyShare: Double) {
            let w = PieceGenerator.poseWeights(d: d)
            let total = w.reduce(0, +)
            let cells = zip(w, ShapeCatalog.all).reduce(0.0) { $0 + $1.0 * Double($1.1.cellCount) } / total
            let heavy = zip(w, ShapeCatalog.all).reduce(0.0) { $0 + ($1.1.cellCount >= 5 ? $1.0 : 0) } / total
            return (cells, heavy)
        }
        var last = stats(0)
        for d in stride(from: 0.05, through: 1.0, by: 0.05) {
            let now = stats(d)
            XCTAssertGreaterThan(now.avgCells, last.avgCells - 1e-9, "average piece size never shrinks as d rises (d=\(d))")
            XCTAssertGreaterThan(now.heavyShare, last.heavyShare - 1e-9)
            last = now
        }
        XCTAssertGreaterThan(stats(1).avgCells, stats(0).avgCells + 0.8)
        XCTAssertGreaterThan(stats(1).heavyShare, 2 * stats(0).heavyShare)
        for d in [0.0, 0.3, 0.6, 1.0] {
            XCTAssertTrue(PieceGenerator.poseWeights(d: d).allSatisfy { $0 > 0 }, "every orientation stays possible")
        }
    }

    func testGeneratorVersionIsStampedOnNewRuns() {
        XCTAssertEqual(GameState(seed: 1).generatorVersion, PieceGenerator.version)
        XCTAssertEqual(GameEngine(seed: 1).state.generatorVersion, PieceGenerator.version)
    }
}
