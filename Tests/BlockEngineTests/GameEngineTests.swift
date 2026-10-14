import XCTest
@testable import BlockEngine

final class GameEngineTests: XCTestCase {
    // Position used by most scripted tests: bottom row is one cell short, plus a lone block that survives.
    private let almostRow7 = ["X.......", "........", "........", "........", "........", "........", "........", "XXXXXXX."]

    // MARK: New game

    func testNewGameDealsAFullTray() {
        let engine = GameEngine(seed: 42)
        let s = engine.state
        XCTAssertEqual(s.tray.compactMap { $0 }.count, 3)
        XCTAssertEqual(s.round, 1)
        XCTAssertEqual(s.score, 0)
        XCTAssertEqual(s.combo, 0)
        XCTAssertEqual(s.movesSinceClear, 0)
        XCTAssertEqual(s.seed, 42)
        XCTAssertTrue(s.board.isEmpty)
        XCTAssertFalse(s.isGameOver)
        XCTAssertEqual(s.generatorVersion, PieceGenerator.version)
        XCTAssertEqual(s.trayHistory.count, 1)
        XCTAssertEqual(s.trayHistory[0], s.tray.compactMap { $0?.shape.id })
        XCTAssertEqual(Set(s.tray.compactMap { $0?.id }).count, 3, "piece ids are unique")
    }

    func testSameSeedSameFirstTrayDifferentSeedDiffers() {
        let a = GameEngine(seed: 5).state, b = GameEngine(seed: 5).state, c = GameEngine(seed: 6).state
        XCTAssertEqual(StateSignature(a), StateSignature(b))
        var differs = false
        for seed in UInt64(6)..<40 where StateSignature(GameEngine(seed: seed).state) != StateSignature(a) { differs = true }
        XCTAssertTrue(differs)
        XCTAssertNotEqual(a.seed, c.seed)
    }

    // MARK: Validation

    func testPlaceRejectsInvalidMovesWithoutChangingState() {
        var engine = makeEngine(rows: almostRow7, tray: ["single", "tri_h", nil])
        let before = engine.state
        XCTAssertNil(engine.place(trayIndex: 0, at: Cell(0, 0)), "occupied cell")
        XCTAssertNil(engine.place(trayIndex: 1, at: Cell(0, 6)), "off the right edge")
        XCTAssertNil(engine.place(trayIndex: 0, at: Cell(8, 0)), "off the board")
        XCTAssertNil(engine.place(trayIndex: 0, at: Cell(-1, 3)))
        XCTAssertNil(engine.place(trayIndex: 2, at: Cell(3, 3)), "slot already placed")
        XCTAssertNil(engine.place(trayIndex: 3, at: Cell(3, 3)), "no such slot")
        XCTAssertNil(engine.place(trayIndex: -1, at: Cell(3, 3)))
        XCTAssertEqual(engine.state, before)
        XCTAssertFalse(engine.canPlace(trayIndex: 0, at: Cell(0, 0)))
        XCTAssertTrue(engine.canPlace(trayIndex: 0, at: Cell(7, 7)))
    }

    func testPlacementRemovesPieceFromTray() {
        var engine = makeEngine(rows: almostRow7, tray: ["single", "tri_h", "domino_v"])
        let outcome = engine.place(trayIndex: 1, at: Cell(3, 3))
        XCTAssertNotNil(outcome)
        XCTAssertNil(engine.state.tray[1])
        XCTAssertEqual(engine.state.tray[0]?.shape.id, "single")
        XCTAssertEqual(engine.state.tray[2]?.shape.id, "domino_v")
        XCTAssertEqual(outcome?.piece.shape.id, "tri_h")
        XCTAssertEqual(outcome?.trayIndex, 1)
        XCTAssertEqual(outcome?.origin, Cell(3, 3))
        XCTAssertEqual(outcome?.newTrayDealt, false)
        XCTAssertEqual(engine.state.piecesPlaced, 1)
        XCTAssertEqual(engine.state.board[3, 4], slotColors[1])
    }

    // MARK: Scoring through the engine

    func testPlacementOnlyScoresOnePointPerCell() {
        var engine = makeEngine(rows: almostRow7, tray: ["l4_a", "single", nil])
        let o = engine.place(trayIndex: 0, at: Cell(2, 2))!
        XCTAssertEqual(o.placementPoints, 4)
        XCTAssertEqual(o.clearPoints, 0)
        XCTAssertEqual(o.allClearBonus, 0)
        XCTAssertEqual(o.totalPoints, 4)
        XCTAssertEqual(o.scoreAfter, 4)
        XCTAssertEqual(engine.state.score, 4)
        XCTAssertNil(o.praise)
    }

    func testSingleLineClearScoresTenAtComboZero() {
        var engine = makeEngine(rows: almostRow7, tray: ["single", "single", "single"])
        let o = engine.place(trayIndex: 0, at: Cell(7, 7))!
        XCTAssertEqual(o.clear.rows, [7])
        XCTAssertEqual(o.placementPoints, 1)
        XCTAssertEqual(o.clearPoints, 10)
        XCTAssertEqual(o.comboBefore, 0)
        XCTAssertEqual(o.comboAfter, 1)
        XCTAssertFalse(o.boardCleared)
        XCTAssertNil(o.praise, "one line earns no word")
        XCTAssertEqual(engine.state.score, 11)
        XCTAssertEqual(engine.state.linesCleared, 1)
        XCTAssertEqual(engine.state.combo, 1)
        XCTAssertEqual(engine.state.movesSinceClear, 0)
    }

    func testThreeLinesAtComboElevenScores720() {
        let board = ["XXXXXXX.", "XXXXXXX.", "XXXXXXX.", "........", "........", "........", "........", "X......."]
        var engine = makeEngine(rows: board, tray: ["tri_v", nil, nil], combo: 11, score: 1000)
        let o = engine.place(trayIndex: 0, at: Cell(0, 7))!
        XCTAssertEqual(o.clear.linesCleared, 3)
        XCTAssertEqual(o.clearPoints, 720)
        XCTAssertEqual(o.totalPoints, 723)               // + 3 cells
        XCTAssertEqual(o.comboBefore, 11)
        XCTAssertEqual(o.comboAfter, 12)
        XCTAssertEqual(o.praise, .great)
        XCTAssertEqual(engine.state.score, 1723)
        XCTAssertEqual(engine.state.bestComboThisGame, 12)
    }

    func testRowAndColumnTogetherCountAsTwoLines() {
        var cells = (0..<8).filter { $0 != 5 }.map { (3, $0) } + (0..<8).filter { $0 != 3 }.map { ($0, 5) }
        cells.append((0, 0))
        var engine = makeEngine(rows: rows(filled: cells), tray: ["single", nil, nil])
        let o = engine.place(trayIndex: 0, at: Cell(3, 5))!
        XCTAssertEqual(o.clear.linesCleared, 2)
        XCTAssertEqual(o.clearPoints, 20)
        XCTAssertEqual(o.praise, .good)
        XCTAssertEqual(o.clear.clearedCells.count, 15)
    }

    func testPraiseForEachLineCount() {
        // vertical pieces dropped into column 7 complete the pre-filled rows above them
        let cases: [(piece: String, lines: Int, praise: Praise)] = [
            ("domino_v", 2, .good), ("tri_v", 3, .great), ("quad_v", 4, .excellent), ("penta_v", 5, .amazing),
        ]
        for c in cases {
            var cells: [(Int, Int)] = []
            for r in 0..<c.lines { for col in 0..<7 { cells.append((r, col)) } }
            cells.append((7, 0))
            var engine = makeEngine(rows: rows(filled: cells), tray: [c.piece, nil, nil])
            let o = engine.place(trayIndex: 0, at: Cell(0, 7))!
            XCTAssertEqual(o.clear.linesCleared, c.lines, c.piece)
            XCTAssertEqual(o.praise, c.praise, c.piece)
        }
        // six lines: a 3x3 dropped into a corner completes 3 rows and 3 columns
        var cells: [(Int, Int)] = []
        for r in 0..<3 { for c in 3..<8 { cells.append((r, c)) } }
        for r in 3..<8 { for c in 0..<3 { cells.append((r, c)) } }
        cells.append((7, 7))
        var engine = makeEngine(rows: rows(filled: cells), tray: ["sq3", nil, nil])
        let o = engine.place(trayIndex: 0, at: Cell(0, 0))!
        XCTAssertEqual(o.clear.linesCleared, 6)
        XCTAssertEqual(o.praise, .incredible)
        XCTAssertEqual(o.clearPoints, 300)
        XCTAssertEqual(o.totalPoints, 309)
    }

    // MARK: Combo window

    func testComboSurvivesTwoMissesAndBreaksOnTheThird() {
        var engine = makeEngine(rows: almostRow7, tray: ["single", "single", "single"])
        let clear = engine.place(trayIndex: 0, at: Cell(7, 7))!
        XCTAssertEqual(clear.comboAfter, 1)

        let miss1 = engine.place(trayIndex: 1, at: Cell(3, 3))!
        XCTAssertEqual(miss1.comboAfter, 1)
        XCTAssertFalse(miss1.comboBroken)
        XCTAssertEqual(engine.state.movesSinceClear, 1)

        let miss2 = engine.place(trayIndex: 2, at: Cell(4, 4))!     // empties the tray: a new one is dealt
        XCTAssertTrue(miss2.newTrayDealt)
        XCTAssertEqual(miss2.comboAfter, 1, "two misses in a row do not break the streak")
        XCTAssertFalse(miss2.comboBroken)
        XCTAssertEqual(engine.state.combo, 1)
        XCTAssertEqual(engine.state.movesSinceClear, 2)

        // third consecutive non-clearing placement, now in the next tray
        var broke: MoveOutcome?
        outer: for i in 0..<3 {
            guard let piece = engine.state.tray[i] else { continue }
            for origin in engine.state.board.validOrigins(for: piece.shape)
            where engine.linesCompleted(trayIndex: i, at: origin).rows.isEmpty && engine.linesCompleted(trayIndex: i, at: origin).cols.isEmpty {
                broke = engine.place(trayIndex: i, at: origin)
                break outer
            }
        }
        XCTAssertEqual(broke?.comboBefore, 1)
        XCTAssertEqual(broke?.comboAfter, 0)
        XCTAssertEqual(broke?.comboBroken, true)
        XCTAssertEqual(engine.state.combo, 0)
    }

    func testClearAfterTwoMissesScoresWithTheStreakAndExtendsIt() {
        var engine = makeEngine(rows: almostRow7, tray: ["single", nil, nil], combo: 1, movesSinceClear: 2)
        let o = engine.place(trayIndex: 0, at: Cell(7, 7))!
        XCTAssertEqual(o.comboBefore, 1)
        XCTAssertEqual(o.clearPoints, 20)                 // L(1) * (1 + 1)
        XCTAssertEqual(o.comboAfter, 2)
        XCTAssertEqual(engine.state.movesSinceClear, 0)
    }

    func testComboWindowIsCountedAcrossTrays() {
        // one piece left in this tray, streak already two misses old
        var engine = makeEngine(rows: ["X......."], tray: ["single", nil, nil], combo: 3, movesSinceClear: 2)
        let o = engine.place(trayIndex: 0, at: Cell(4, 4))!
        XCTAssertTrue(o.newTrayDealt)
        XCTAssertTrue(o.comboBroken)
        XCTAssertEqual(o.comboBefore, 3)
        XCTAssertEqual(o.comboAfter, 0)
        XCTAssertEqual(engine.state.combo, 0)
        XCTAssertEqual(engine.state.round, 2)
    }

    func testMissWithoutAStreakIsNeverReportedAsBroken() {
        var engine = makeEngine(rows: ["X......."], tray: ["single", "single", "single"], combo: 0, movesSinceClear: 7)
        let o = engine.place(trayIndex: 0, at: Cell(4, 4))!
        XCTAssertFalse(o.comboBroken)
        XCTAssertEqual(o.comboAfter, 0)
    }

    // MARK: All Clear

    func testAllClearBonusIsFlatAndUnmultiplied() {
        var engine = makeEngine(rows: ["........", "........", "........", "........", "........", "........", "........", "XXXXXXX."],
                                tray: ["single", nil, nil], combo: 2, score: 500)
        let o = engine.place(trayIndex: 0, at: Cell(7, 7))!
        XCTAssertTrue(o.boardCleared)
        XCTAssertTrue(engine.state.board.isEmpty)
        XCTAssertEqual(o.clearPoints, 30)                 // L(1) * (2 + 1)
        XCTAssertEqual(o.allClearBonus, 300)              // not multiplied by the combo
        XCTAssertEqual(o.totalPoints, 1 + 30 + 300)
        XCTAssertEqual(o.praise, .unbelievable)
        XCTAssertEqual(engine.state.allClears, 1)
        XCTAssertEqual(engine.state.score, 831)
        XCTAssertEqual(o.comboAfter, 3)
    }

    func testPlacingOnAnEmptyBoardIsNotAnAllClear() {
        var engine = makeEngine(rows: [], tray: ["single", "single", "single"])
        let o = engine.place(trayIndex: 0, at: Cell(0, 0))!
        XCTAssertFalse(o.boardCleared)
        XCTAssertEqual(o.allClearBonus, 0)
        XCTAssertEqual(engine.state.allClears, 0)
    }

    // MARK: Trays

    func testNewTrayIsDealtWhenAllThreeArePlaced() {
        var engine = GameEngine(seed: 11)
        var mover = Mover(seed: 3, seeksLines: false)
        let firstTray = engine.state.tray.compactMap { $0?.shape.id }
        var dealtAt: Int?
        for step in 1...3 {
            let move = mover.next(engine)!
            let o = engine.place(trayIndex: move.trayIndex, at: move.origin)!
            if o.newTrayDealt { dealtAt = step }
        }
        XCTAssertEqual(dealtAt, 3)
        XCTAssertEqual(engine.state.round, 2)
        XCTAssertEqual(engine.state.tray.compactMap { $0 }.count, 3)
        XCTAssertEqual(engine.state.trayHistory.count, 2)
        XCTAssertEqual(engine.state.trayHistory[0], firstTray)
        XCTAssertEqual(engine.state.trayHistory[1], engine.state.tray.compactMap { $0?.shape.id })
    }

    func testTrayHistoryKeepsOnlyTheLastTwoTrays() {
        var engine = GameEngine(seed: 12)
        var mover = Mover(seed: 4, seeksLines: true)
        var trays = [engine.state.tray.compactMap { $0?.shape.id }]
        for _ in 0..<30 where !engine.state.isGameOver {
            let move = mover.next(engine)!
            if engine.place(trayIndex: move.trayIndex, at: move.origin)!.newTrayDealt {
                trays.append(engine.state.tray.compactMap { $0?.shape.id })
            }
        }
        XCTAssertGreaterThan(trays.count, 3)
        XCTAssertEqual(engine.state.trayHistory, Array(trays.suffix(2)))
        XCTAssertEqual(engine.state.round, trays.count)
    }

    func testDealtTrayIsAlwaysPlaceableSoItNeverEndsTheGame() {
        var engine = GameEngine(seed: 77)
        var mover = Mover(seed: 78, seeksLines: true)
        for _ in 0..<200 where !engine.state.isGameOver {
            let move = mover.next(engine)!
            let o = engine.place(trayIndex: move.trayIndex, at: move.origin)!
            if o.newTrayDealt {
                XCTAssertFalse(o.isGameOver, "a freshly dealt tray always has a move")
                XCTAssertTrue(Solver.canPlaceAll(engine.state.tray.compactMap { $0?.shape }, on: engine.state.board.occupancy))
            }
        }
    }

    // MARK: Game over

    /// Checkerboard: every empty cell is isolated, so only singles and diagonals fit.
    private let checkerboard = ["X.X.X.X.", ".X.X.X.X", "X.X.X.X.", ".X.X.X.X", "X.X.X.X.", ".X.X.X.X", "X.X.X.X.", ".X.X.X.X"]

    func testGameOverWhenNothingLeftInTheTrayFits() {
        var engine = makeEngine(rows: checkerboard, tray: ["single", "tri_h", nil])
        XCTAssertFalse(engine.state.isGameOver)
        XCTAssertTrue(engine.isPlaceableAnywhere(trayIndex: 0))
        XCTAssertFalse(engine.isPlaceableAnywhere(trayIndex: 1))
        XCTAssertFalse(engine.isPlaceableAnywhere(trayIndex: 2), "empty slot")

        let o = engine.place(trayIndex: 0, at: Cell(0, 1))!
        XCTAssertTrue(o.clear.rows.isEmpty && o.clear.cols.isEmpty)
        XCTAssertTrue(o.isGameOver)
        XCTAssertTrue(engine.state.isGameOver)
        XCTAssertFalse(o.newTrayDealt)
        XCTAssertNil(engine.place(trayIndex: 1, at: Cell(2, 3)), "no moves after game over")
        XCTAssertFalse(engine.canPlace(trayIndex: 1, at: Cell(2, 3)))
    }

    func testNotGameOverWhileAnyPieceStillFits() {
        var engine = makeEngine(rows: checkerboard, tray: ["single", "tri_h", "single"])
        let o = engine.place(trayIndex: 0, at: Cell(0, 1))!
        XCTAssertFalse(o.isGameOver, "the other single still fits")
        XCTAssertFalse(engine.state.isGameOver)
    }

    func testClearThatFreesSpaceKeepsTheGameGoing() {
        // the tri_h only fits once the single has cleared row 7
        var board = checkerboard
        board[7] = "XXXXXXX."
        var engine = makeEngine(rows: board, tray: ["single", "tri_h", nil])
        XCTAssertFalse(engine.isPlaceableAnywhere(trayIndex: 1))
        let o = engine.place(trayIndex: 0, at: Cell(7, 7))!
        XCTAssertEqual(o.clear.rows, [7])
        XCTAssertFalse(o.isGameOver)
        XCTAssertTrue(engine.isPlaceableAnywhere(trayIndex: 1))
    }

    func testRandomPlayAlwaysEndsEventually() {
        for seed in UInt64(0)..<20 {
            var engine = GameEngine(seed: seed)
            var mover = Mover(seed: seed &+ 1000, seeksLines: false)
            var moves = 0
            while !engine.state.isGameOver, let move = mover.next(engine) {
                XCTAssertNotNil(engine.place(trayIndex: move.trayIndex, at: move.origin))
                moves += 1
                XCTAssertLessThan(moves, 2000)
            }
            XCTAssertTrue(engine.state.isGameOver)
            XCTAssertNil(mover.next(engine).flatMap { engine.canPlace(trayIndex: $0.trayIndex, at: $0.origin) ? $0 : nil })
        }
    }

    // MARK: Preview queries

    func testLinesCompletedPreview() {
        let engine = makeEngine(rows: almostRow7, tray: ["single", "domino_v", nil])
        XCTAssertEqual(engine.linesCompleted(trayIndex: 0, at: Cell(7, 7)).rows, [7])
        XCTAssertEqual(engine.linesCompleted(trayIndex: 0, at: Cell(3, 3)).rows, [])
        XCTAssertEqual(engine.linesCompleted(trayIndex: 0, at: Cell(0, 0)).rows, [], "occupied")
        XCTAssertEqual(engine.linesCompleted(trayIndex: 2, at: Cell(7, 7)).rows, [], "empty slot")
        XCTAssertEqual(engine.linesCompleted(trayIndex: 9, at: Cell(7, 7)).rows, [])
    }

    // MARK: Stats

    func testRunStatisticsAccumulate() {
        var engine = makeEngine(rows: ["........", "........", "........", "........", "........", "........", "........", "XXXXXXX."],
                                tray: ["single", "domino_h", "single"])
        engine.place(trayIndex: 0, at: Cell(7, 7))            // All Clear
        engine.place(trayIndex: 1, at: Cell(0, 0))
        XCTAssertEqual(engine.state.piecesPlaced, 2)
        XCTAssertEqual(engine.state.linesCleared, 1)
        XCTAssertEqual(engine.state.allClears, 1)
        XCTAssertEqual(engine.state.bestComboThisGame, 1)
        XCTAssertEqual(engine.state.combo, 1)
        XCTAssertEqual(engine.state.score, (1 + 10 + 300) + 2)
    }

    // MARK: Persistence and resume

    func testRestoringNeverRedealsAPartiallyPlayedTray() {
        var engine = GameEngine(seed: 21)
        var mover = Mover(seed: 22, seeksLines: false)
        let move = mover.next(engine)!
        engine.place(trayIndex: move.trayIndex, at: move.origin)
        let saved = engine.state
        let restored = GameEngine(restoring: saved)
        XCTAssertEqual(restored.state, saved, "resume is exact, including piece ids and RNG state")
    }

    func testRestoringAnEmptyTrayOnALiveGameDealsOne() {
        var state = GameState(seed: 31)
        state.tray = [nil, nil, nil]
        let restored = GameEngine(restoring: state)
        XCTAssertEqual(restored.state.tray.compactMap { $0 }.count, 3)
        XCTAssertEqual(restored.state.round, 1)
        XCTAssertFalse(restored.state.isGameOver)
    }

    func testRestoringAFinishedGameStaysFinished() {
        var engine = makeEngine(rows: checkerboard, tray: ["single", "tri_h", nil])
        engine.place(trayIndex: 0, at: Cell(0, 1))
        XCTAssertTrue(engine.state.isGameOver)
        let restored = GameEngine(restoring: engine.state)
        XCTAssertEqual(restored.state, engine.state)
        XCTAssertEqual(restored.state.tray.compactMap { $0 }.count, 1, "no new tray after game over")
    }

    func testCodableRoundTripMidGameResumesIdentically() throws {
        var original = GameEngine(seed: 2025)
        var mover = Mover(seed: 9, seeksLines: true)
        for _ in 0..<45 where !original.state.isGameOver {
            let move = mover.next(original)!
            original.place(trayIndex: move.trayIndex, at: move.origin)
        }
        XCTAssertFalse(original.state.isGameOver)
        XCTAssertGreaterThan(original.state.round, 10, "the save point should be well into the run")

        let data = try JSONEncoder().encode(original.state)
        let decoded = try JSONDecoder().decode(GameState.self, from: data)
        XCTAssertEqual(decoded, original.state, "a Codable round trip is lossless")
        var resumed = GameEngine(restoring: decoded)

        // Play the same moves on both; trays, scores, combos and RNG must stay in lockstep.
        var moverA = mover, moverB = mover
        for step in 0..<150 where !original.state.isGameOver {
            let a = moverA.next(original)!, b = moverB.next(resumed)!
            XCTAssertEqual(a.trayIndex, b.trayIndex, "step \(step)")
            XCTAssertEqual(a.origin, b.origin, "step \(step)")
            let outA = original.place(trayIndex: a.trayIndex, at: a.origin)!
            let outB = resumed.place(trayIndex: b.trayIndex, at: b.origin)!
            XCTAssertEqual(outA.totalPoints, outB.totalPoints)
            XCTAssertEqual(outA.praise, outB.praise)
            XCTAssertEqual(StateSignature(original.state), StateSignature(resumed.state), "step \(step)")
        }
        XCTAssertEqual(original.state.isGameOver, resumed.state.isGameOver)
    }

    func testSameSeedAndMovesGiveTheSameGame() {
        func play(_ seed: UInt64) -> [StateSignature] {
            var engine = GameEngine(seed: seed)
            var mover = Mover(seed: 5, seeksLines: true)
            var log: [StateSignature] = []
            for _ in 0..<80 where !engine.state.isGameOver {
                guard let move = mover.next(engine) else { break }
                engine.place(trayIndex: move.trayIndex, at: move.origin)
                log.append(StateSignature(engine.state))
            }
            return log
        }
        XCTAssertEqual(play(314), play(314))
        XCTAssertNotEqual(play(314), play(315))
    }
}
