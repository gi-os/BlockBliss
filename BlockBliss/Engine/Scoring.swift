import Foundation

/// The community-measured Block Blast scoring formula (base b = 5), exactly as written in SPEC.md.
///
///  - Placement: +1 point per cell of the placed piece.
///  - Line clear: `L(n) x (C + 1)` where n = lines cleared by this placement and C = combo *before* it.
///  - All Clear: a flat +300 that the combo does not multiply.
public enum Scoring {
    /// A streak breaks on the 3rd consecutive non-clearing placement (it survives up to 2 misses).
    public static let comboWindow = 3
    public static let allClearBonus = 300

    /// L(n): 10 for one line, then 10·n·(n−1): 20, 60, 120, 200, 300 for 2...6 lines.
    public static func lineValue(_ lines: Int) -> Int {
        switch lines {
        case ..<1: return 0
        case 1: return 10
        default: return 10 * lines * (lines - 1)
        }
    }

    /// Points for the line clear of one placement: `L(lines) x (comboBefore + 1)`.
    public static func clearPoints(lines: Int, comboBefore: Int) -> Int {
        lineValue(lines) * (max(0, comboBefore) + 1)
    }

    /// Praise word for one move. Emptying the board takes precedence over the line-count word;
    /// a single line earns no word.
    public static func praise(lines: Int, boardCleared: Bool) -> Praise? {
        if boardCleared { return .unbelievable }
        switch lines {
        case ..<2: return nil
        case 2: return .good
        case 3: return .great
        case 4: return .excellent
        case 5: return .amazing
        default: return .incredible
        }
    }

    /// Advances the streak counters after one placement (the iOS "rolling" rule).
    ///
    ///  - A clearing move scores with the current combo, then `combo += 1` and `movesSinceClear = 0`.
    ///  - A non-clearing move does `movesSinceClear += 1`; once that reaches `comboWindow` the combo drops
    ///    to 0, which counts as `broken` only if there was a streak to lose.
    public static func advanceCombo(combo: Int, movesSinceClear: Int, linesCleared: Int)
        -> (combo: Int, movesSinceClear: Int, broken: Bool) {
        if linesCleared > 0 {
            return (combo + 1, 0, false)
        }
        let misses = movesSinceClear + 1
        if misses >= comboWindow {
            return (0, misses, combo > 0)
        }
        return (combo, misses, false)
    }
}
