import XCTest
@testable import BlockEngine

final class ScoringTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(Scoring.comboWindow, 3)
        XCTAssertEqual(Scoring.allClearBonus, 300)
    }

    func testLineValueTable() {
        // L(1)=10, L(n)=10*n*(n-1) for n>=2
        XCTAssertEqual((1...6).map(Scoring.lineValue), [10, 20, 60, 120, 200, 300])
        XCTAssertEqual(Scoring.lineValue(0), 0)
        XCTAssertEqual(Scoring.lineValue(-3), 0)
        XCTAssertEqual(Scoring.lineValue(7), 420)
    }

    func testClearPointsWorkedExamples() {
        XCTAssertEqual(Scoring.clearPoints(lines: 1, comboBefore: 0), 10)
        XCTAssertEqual(Scoring.clearPoints(lines: 1, comboBefore: 1), 20)
        XCTAssertEqual(Scoring.clearPoints(lines: 2, comboBefore: 4), 100)       // 20 * 5
        XCTAssertEqual(Scoring.clearPoints(lines: 3, comboBefore: 11), 720)      // 60 * 12
        XCTAssertEqual(Scoring.clearPoints(lines: 6, comboBefore: 0), 300)
        XCTAssertEqual(Scoring.clearPoints(lines: 6, comboBefore: 9), 3000)
        XCTAssertEqual(Scoring.clearPoints(lines: 0, comboBefore: 50), 0)
    }

    func testPraiseMapping() {
        XCTAssertNil(Scoring.praise(lines: 0, boardCleared: false))
        XCTAssertNil(Scoring.praise(lines: 1, boardCleared: false))
        XCTAssertEqual(Scoring.praise(lines: 2, boardCleared: false), .good)
        XCTAssertEqual(Scoring.praise(lines: 3, boardCleared: false), .great)
        XCTAssertEqual(Scoring.praise(lines: 4, boardCleared: false), .excellent)
        XCTAssertEqual(Scoring.praise(lines: 5, boardCleared: false), .amazing)
        XCTAssertEqual(Scoring.praise(lines: 6, boardCleared: false), .incredible)
        // All Clear wins over the line-count word, even for a single line
        XCTAssertEqual(Scoring.praise(lines: 1, boardCleared: true), .unbelievable)
        XCTAssertEqual(Scoring.praise(lines: 4, boardCleared: true), .unbelievable)
        XCTAssertEqual(Praise.unbelievable.text, "Unbelievable!")
    }

    func testAdvanceComboClearIncrementsAndResetsWindow() {
        let r = Scoring.advanceCombo(combo: 4, movesSinceClear: 2, linesCleared: 2)
        XCTAssertEqual(r.combo, 5)
        XCTAssertEqual(r.movesSinceClear, 0)
        XCTAssertFalse(r.broken)
    }

    func testStreakSurvivesTwoMissesAndBreaksOnTheThird() {
        var combo = 3, since = 0
        var step = Scoring.advanceCombo(combo: combo, movesSinceClear: since, linesCleared: 0)
        XCTAssertEqual(step.combo, 3); XCTAssertEqual(step.movesSinceClear, 1); XCTAssertFalse(step.broken)
        (combo, since) = (step.combo, step.movesSinceClear)
        step = Scoring.advanceCombo(combo: combo, movesSinceClear: since, linesCleared: 0)
        XCTAssertEqual(step.combo, 3); XCTAssertEqual(step.movesSinceClear, 2); XCTAssertFalse(step.broken)
        (combo, since) = (step.combo, step.movesSinceClear)
        step = Scoring.advanceCombo(combo: combo, movesSinceClear: since, linesCleared: 0)
        XCTAssertEqual(step.combo, 0); XCTAssertTrue(step.broken)
    }

    func testBreakingWithNoStreakIsNotReportedAsBroken() {
        let step = Scoring.advanceCombo(combo: 0, movesSinceClear: 5, linesCleared: 0)
        XCTAssertEqual(step.combo, 0)
        XCTAssertFalse(step.broken)
    }

    func testClearAfterTwoMissesKeepsTheStreakAlive() {
        var (combo, since) = (2, 2)
        let step = Scoring.advanceCombo(combo: combo, movesSinceClear: since, linesCleared: 1)
        (combo, since) = (step.combo, step.movesSinceClear)
        XCTAssertEqual(combo, 3)
        XCTAssertEqual(since, 0)
    }
}
