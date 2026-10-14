import Foundation
import Observation
import SwiftUI

// MARK: - Drag state

/// Where the player would drop the piece they are holding, with everything the board needs to preview it.
/// Only exists while the drop is valid, so an invalid spot shows nothing.
struct DropPreview: Equatable {
    let shape: Shape
    let color: BlockColor
    let origin: Cell
    /// Rows and columns this drop would complete.
    let rows: [Int]
    let cols: [Int]

    var cells: [Cell] { shape.cells.map { Cell(row: origin.row + $0.row, col: origin.col + $0.col) } }
}

/// State of the piece in the player's hand. Kept apart from the game model so that finger movement
/// (60 Hz) only invalidates the small views that read it, never the HUD or the tray.
@Observable @MainActor
final class DragModel {
    /// Tray slot of the piece being held (or springing back). nil when nothing is lifted.
    var trayIndex: Int?
    /// Finger position in the "game" coordinate space.
    var finger: CGPoint = .zero
    /// 0 = resting in its tray slot at tray scale, 1 = lifted at board scale above the finger.
    var lift: CGFloat = 0
    var preview: DropPreview?
    /// True while the finger is down.
    var isHolding = false
    /// Changes on every pick-up so SwiftUI treats each lift as a new view (and plays its lift animation).
    var pickID = 0

    @ObservationIgnored var startFinger: CGPoint = .zero
    @ObservationIgnored var lastOrigin: Cell?
    @ObservationIgnored var returnToken = 0
}

// MARK: - Move effects

/// Everything the effects layer needs to animate one placement. Created in the same update as the
/// engine move so the board and the effect change on the very same frame.
struct MoveEffect: Identifiable {
    let id: Int
    let start: Date
    /// Board cells of the piece that was just dropped.
    let placed: [Cell]
    /// Cells removed by this move (includes just-placed cells), with the colour they had.
    let cleared: [ClearedCell]
    let rows: [Int]
    let cols: [Int]
    let points: Int
    let praise: Praise?
    let allClearBonus: Int
    let comboAfter: Int
    /// Captured at creation: Reduce Effects = no particles, no sweep, plain fades.
    let reduced: Bool

    var isClear: Bool { !cleared.isEmpty }
    var lines: Int { rows.count + cols.count }
    var isAllClear: Bool { allClearBonus > 0 }

    /// How long the effect (including its text popups) stays in the view tree.
    var lifetime: TimeInterval {
        if !isClear { return 0.35 }
        return reduced ? 1.4 : 1.9
    }

    /// Centre of the dropped piece in cell units; clear animations spread outward from here.
    var dropCenter: CGPoint {
        guard !placed.isEmpty else { return CGPoint(x: 3.5, y: 3.5) }
        let n = CGFloat(placed.count)
        return CGPoint(x: placed.reduce(0) { $0 + CGFloat($1.col) } / n,
                       y: placed.reduce(0) { $0 + CGFloat($1.row) } / n)
    }

    /// Centre of the cleared cells in cell units (where the "+N" popup rises from).
    var clearCenter: CGPoint {
        guard !cleared.isEmpty else { return dropCenter }
        let n = CGFloat(cleared.count)
        return CGPoint(x: cleared.reduce(0) { $0 + CGFloat($1.cell.col) } / n,
                       y: cleared.reduce(0) { $0 + CGFloat($1.cell.row) } / n)
    }
}

// MARK: - View model

/// Owns the engine, the lifetime records and everything the UI needs to present a run.
/// Best score and stats live here only; they are never passed to the engine (see GENERATOR.md).
@Observable @MainActor
final class GameViewModel {
    enum Phase: Equatable {
        case playing
        /// "No Space Left" band is showing (about 1.2 s).
        case noSpace
        /// The game-over card is showing. Stays until the player taps Play Again.
        case gameOver
    }

    private(set) var engine: GameEngine
    private(set) var records: Records
    private(set) var phase: Phase
    private(set) var effects: [MoveEffect] = []
    /// Bumped to trigger a board shake (3+ lines, Reduce Effects off).
    private(set) var shakeTick = 0
    private(set) var shakeStrength: CGFloat = 0

    let drag = DragModel()

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let persistence: Persistence
    @ObservationIgnored private var nextEffectID = 0
    @ObservationIgnored private var gameOverTask: Task<Void, Never>?

    /// How long the "No Space Left" band is shown before the game-over card.
    private static let noSpaceDuration: Duration = .milliseconds(1200)
    /// A touch that moves less than this (in points) is a tap, not a drop.
    private static let tapSlop: CGFloat = 10

    // MARK: Derived

    var state: GameState { engine.state }
    var isGameOver: Bool { state.isGameOver }
    /// The best score shown in the HUD (live: it rises as soon as the run passes it).
    var bestScore: Int { max(records.bestScore, state.score) }
    /// True when this run beat the best score the player had when it began.
    var isNewBest: Bool { state.score > 0 && state.score > records.bestAtRunStart }

    func isPlaceable(trayIndex: Int) -> Bool { engine.isPlaceableAnywhere(trayIndex: trayIndex) }

    // MARK: Lifecycle

    init(settings: Settings, persistence: Persistence = .shared) {
        self.settings = settings
        self.persistence = persistence

        var loaded = persistence.loadRecords()
        if let saved = persistence.loadGame() {
            // Resume exactly where the player left off, including a finished game (never auto-restart).
            engine = GameEngine(restoring: saved)
            phase = saved.isGameOver ? .gameOver : .playing
            records = loaded
        } else {
            // First launch or no saved run: start a new game.
            loaded.bestAtRunStart = loaded.bestScore
            records = loaded
            engine = GameEngine(seed: Self.makeSeed())
            phase = .playing
            persist()
        }
    }

    private static func makeSeed() -> UInt64 {
        #if DEBUG
        // Reproducible runs for development: BLOCKBLISS_SEED=12345
        if let text = ProcessInfo.processInfo.environment["BLOCKBLISS_SEED"], let seed = UInt64(text) { return seed }
        #endif
        return UInt64.random(in: UInt64.min...UInt64.max)
    }

    /// Starts a fresh run. Called by "Play Again" and by "New Game" in Settings (after confirmation).
    func newGame() {
        gameOverTask?.cancel()
        dismissDrag()
        // An abandoned run still counts as a game played; finished runs were already counted.
        if phase == .playing && state.piecesPlaced > 0 { records.gamesPlayed += 1 }
        records.bestAtRunStart = records.bestScore
        engine = GameEngine(seed: Self.makeSeed())
        phase = .playing
        effects.removeAll()
        persist()
    }

    /// Writes the run and the records to disk. Cheap; called after every move.
    func persist() {
        persistence.save(game: engine.state)
        persistence.save(records: records)
    }

    /// Called when the app leaves the foreground: put any held piece back, then make sure it's on disk.
    func appWillResignActive() {
        cancelHeldPiece()
        persist()
        persistence.flush()
    }

    // MARK: Dragging

    /// Lifts the piece in `trayIndex`. Returns false if nothing can be picked up there.
    @discardableResult
    func beginDrag(trayIndex: Int, finger: CGPoint) -> Bool {
        guard phase == .playing,
              state.tray.indices.contains(trayIndex),
              state.tray[trayIndex] != nil else { return false }
        // A spring-back may still be in flight; the new pick-up supersedes it.
        drag.returnToken &+= 1
        drag.pickID &+= 1
        drag.trayIndex = trayIndex
        drag.finger = finger
        drag.startFinger = finger
        drag.lastOrigin = nil
        drag.preview = nil
        drag.lift = 0
        drag.isHolding = true
        SoundEngine.shared.play(.pickup)
        Haptics.shared.pickup()
        return true
    }

    /// Plays the lift animation. Called by the lifted piece's view once it is on screen, so the
    /// animation always starts from the resting pose.
    func raiseHeldPiece() {
        guard drag.isHolding else { return }
        withAnimation(.easeOut(duration: 0.12)) { drag.lift = 1 }
    }

    /// Moves the held piece and refreshes the drop preview. `origin` is the snapped board cell.
    func updateDrag(finger: CGPoint, origin: Cell) {
        guard drag.isHolding, let index = drag.trayIndex, let piece = state.tray[index] else { return }
        drag.finger = finger
        guard origin != drag.lastOrigin else { return }
        drag.lastOrigin = origin

        let preview: DropPreview?
        if engine.canPlace(trayIndex: index, at: origin) {
            let lines = engine.linesCompleted(trayIndex: index, at: origin)
            preview = DropPreview(shape: piece.shape, color: piece.color, origin: origin, rows: lines.rows, cols: lines.cols)
        } else {
            preview = nil
        }
        if drag.preview != preview { drag.preview = preview }
    }

    /// Releases the held piece at `origin`: places it if the spot is valid, otherwise springs it back.
    func endDrag(finger: CGPoint, origin: Cell) {
        guard drag.isHolding, let index = drag.trayIndex else { return }
        drag.isHolding = false
        drag.preview = nil
        drag.lastOrigin = nil

        // A touch that never really moved is a tap on the tray, not a drop: the lifted piece floats over the
        // board's bottom rows, and a tap must never place it by accident. Put it back without a sound.
        let moved = hypot(finger.x - drag.startFinger.x, finger.y - drag.startFinger.y) > Self.tapSlop
        guard moved else {
            returnToTray(silent: true)
            return
        }

        if engine.canPlace(trayIndex: index, at: origin), let outcome = engine.place(trayIndex: index, at: origin) {
            drag.trayIndex = nil
            drag.lift = 0
            apply(outcome)
        } else {
            returnToTray(silent: false)
        }
    }

    /// Puts a held piece back without a sound: the touch was cancelled by the system or a sheet opened.
    func cancelHeldPiece() {
        guard drag.isHolding else { return }
        returnToTray(silent: true)
    }

    /// Springs the held piece back to its slot. `silent` skips the "nope" cue (a plain tap, or an interruption).
    private func returnToTray(silent: Bool) {
        drag.isHolding = false
        drag.preview = nil
        drag.lastOrigin = nil
        drag.returnToken &+= 1
        let token = drag.returnToken
        let animation: Animation = settings.reduceEffects
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.25, dampingFraction: 0.78)
        withAnimation(animation) { drag.lift = 0 }
        if !silent {
            SoundEngine.shared.play(.invalid)
            Haptics.shared.invalid()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard let self, self.drag.returnToken == token, !self.drag.isHolding else { return }
            self.drag.trayIndex = nil
        }
    }

    /// Drops any held piece immediately, without animation.
    private func dismissDrag() {
        drag.returnToken &+= 1
        drag.isHolding = false
        drag.trayIndex = nil
        drag.preview = nil
        drag.lastOrigin = nil
        drag.lift = 0
    }

    // MARK: Applying a move

    private func apply(_ outcome: MoveOutcome) {
        let s = engine.state

        // Lifetime records (never read by the engine).
        var r = records
        r.bestScore = max(r.bestScore, s.score)
        r.bestCombo = max(r.bestCombo, s.bestComboThisGame)
        r.totalLines += outcome.clear.linesCleared
        r.totalPieces += 1
        if outcome.boardCleared { r.allClears += 1 }
        if outcome.isGameOver { r.gamesPlayed += 1 }
        records = r

        playFeedback(for: outcome)
        spawnEffect(for: outcome)
        persist()

        if outcome.isGameOver { beginGameOver() }
    }

    private func playFeedback(for outcome: MoveOutcome) {
        let sound = SoundEngine.shared
        let haptics = Haptics.shared
        let lines = outcome.clear.linesCleared
        if lines > 0 {
            sound.play(.clear(lines: lines, combo: outcome.comboAfter))
            if outcome.boardCleared {
                sound.play(.allClear)
                haptics.allClear()
            } else {
                haptics.clear(lines: lines)
            }
        } else {
            sound.play(.place)
            haptics.place()
        }
    }

    private func spawnEffect(for outcome: MoveOutcome) {
        let reduced = settings.reduceEffects
        let lines = outcome.clear.linesCleared
        // Without Reduce Effects every placement gets a quick settle flash; with it only clears animate.
        guard lines > 0 || !reduced else { return }

        nextEffectID += 1
        let effect = MoveEffect(
            id: nextEffectID,
            start: .now,
            placed: outcome.clear.placedCells,
            cleared: outcome.clear.clearedCells,
            rows: outcome.clear.rows,
            cols: outcome.clear.cols,
            points: outcome.totalPoints,
            praise: outcome.praise,
            allClearBonus: outcome.allClearBonus,
            comboAfter: outcome.comboAfter,
            reduced: reduced)
        effects.append(effect)

        if lines >= 3 && !reduced {
            shakeStrength = CGFloat(min(lines, 6)) * 1.1
            shakeTick += 1
        }

        let id = effect.id
        let lifetime = effect.lifetime
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            self?.effects.removeAll { $0.id == id }
        }
    }

    // MARK: Game over

    private func beginGameOver() {
        phase = .noSpace
        if !isNewBest {
            SoundEngine.shared.play(.gameOver)
            Haptics.shared.gameOver()
        }
        gameOverTask?.cancel()
        gameOverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noSpaceDuration)
            guard !Task.isCancelled, let self, self.phase == .noSpace else { return }
            self.phase = .gameOver
            if self.isNewBest {
                SoundEngine.shared.play(.newBest)
                Haptics.shared.newBest()
            }
        }
    }
}
