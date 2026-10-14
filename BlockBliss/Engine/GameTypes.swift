import Foundation

/// Praise shown after a clearing move. Chosen purely from what happened on that move.
public enum Praise: String, Codable, Sendable {
    case good          // 2 lines
    case great         // 3 lines
    case excellent     // 4 lines
    case amazing       // 5 lines
    case incredible    // 6 lines
    case unbelievable  // board fully cleared ("All Clear")

    public var text: String {
        switch self {
        case .good: return "Good!"
        case .great: return "Great!"
        case .excellent: return "Excellent!"
        case .amazing: return "Amazing!"
        case .incredible: return "Incredible!"
        case .unbelievable: return "Unbelievable!"
        }
    }
}

/// Complete, persistable state of one run. Deliberately contains nothing about the player's best
/// score or history: the piece generator can only ever see the board, this run's score and round,
/// and its own seeded RNG.
public struct GameState: Codable, Equatable, Sendable {
    public var board: Board
    /// Always exactly 3 slots; `nil` once that slot's piece has been placed.
    public var tray: [Piece?]
    public var score: Int
    /// Number of consecutive clearing moves in the current streak (0 = no streak).
    public var combo: Int
    /// Placements since the last clearing move. The streak breaks when this reaches `Scoring.comboWindow`.
    public var movesSinceClear: Int
    /// Number of trays dealt so far (1 after the first deal).
    public var round: Int
    public var piecesPlaced: Int
    public var linesCleared: Int
    public var bestComboThisGame: Int
    public var allClears: Int
    /// Seed this run started from (shown on the game-over screen so any run can be replayed).
    public var seed: UInt64
    /// Drives piece selection only.
    public var rng: SeededRNG
    /// Separate stream for colours so colour choice can never perturb which shapes are dealt.
    public var colorRNG: SeededRNG
    /// Shape ids of the last two trays dealt (most recent last), used only for repetition control.
    public var trayHistory: [[String]]
    public var isGameOver: Bool
    public var generatorVersion: Int

    public init(seed: UInt64) {
        board = Board()
        tray = [nil, nil, nil]
        score = 0
        combo = 0
        movesSinceClear = 0
        round = 0
        piecesPlaced = 0
        linesCleared = 0
        bestComboThisGame = 0
        allClears = 0
        self.seed = seed
        rng = SeededRNG(seed: seed)
        colorRNG = SeededRNG(seed: seed ^ 0xC0FF_EE00_D15E_A5E5)
        trayHistory = []
        isGameOver = false
        generatorVersion = PieceGenerator.version
    }

    public var remainingPieces: [Piece] { tray.compactMap { $0 } }
}

/// Everything the UI needs to animate and score one placement.
public struct MoveOutcome: Sendable {
    public let trayIndex: Int
    public let piece: Piece
    public let origin: Cell
    public let clear: ClearResult

    public let placementPoints: Int
    public let clearPoints: Int
    public let allClearBonus: Int
    public var totalPoints: Int { placementPoints + clearPoints + allClearBonus }

    /// Streak length before / after this move.
    public let comboBefore: Int
    public let comboAfter: Int
    /// True when this (non-clearing) placement ended an active streak.
    public let comboBroken: Bool
    public let boardCleared: Bool
    public let praise: Praise?

    /// True when this placement emptied the tray and a fresh tray of 3 was dealt.
    public let newTrayDealt: Bool
    /// True when, after this move, none of the pieces left in the tray fit anywhere.
    public let isGameOver: Bool
    public let scoreAfter: Int
}
