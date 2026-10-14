# Block Bliss — spec

A faithful, honest clone of **Block Blast! (Classic mode)** for iPhone. It has the same rules, scoring, feel and difficulty ramp. It leaves out the ads, revives, rigging, tracking, nags and pressure.

Target: iOS 17+, iPhone only, portrait only, SwiftUI, Swift 5 language mode (Swift 6.3 compiler). No third-party dependencies. No network access at all.

## Project layout

```
BlockBliss/                      ← repo root (xcodegen project.yml + Package.swift live here)
  project.yml                    ← xcodegen; app sources = BlockBliss/ (all subfolders)
  Package.swift                  ← macOS SwiftPM package: target BlockEngine = BlockBliss/Engine, tests, blocksim CLI
  BlockBliss/
    Engine/      Foundation-only game logic. MUST NOT import SwiftUI/UIKit/AVFoundation.
      Models.swift      (written — Cell, BlockColor, BitBoard, PieceFamily, Shape, Piece, Board, ClearResult, SeededRNG)
      GameTypes.swift   (written — Praise, GameState, MoveOutcome)
      ShapeCatalog.swift, Scoring.swift, Solver.swift, PieceGenerator.swift, GameEngine.swift  (engine agent)
    Game/        App-side model layer (UIKit/AVFoundation allowed)
      GameViewModel.swift, Persistence.swift, Settings.swift   (UI agent)
      SoundEngine.swift, Haptics.swift                        (audio agent)
    Views/       SwiftUI views (UI agent)
      Theme.swift (colours/fonts), BlockView.swift, BoardView.swift, TrayView.swift, GameView.swift,
      HUDView.swift, EffectsLayer.swift, GameOverView.swift, SettingsView.swift, FairPlayView.swift …
    App/BlockBlissApp.swift  (UI agent)
    Resources/Assets.xcassets (AppIcon done, AccentColor done)
  Tests/BlockEngineTests/   XCTest for the engine (engine agent)
  Tools/blocksim/main.swift Monte-Carlo simulator CLI (engine agent)
```

Engine types are `public` so they compile both inside the app target (same module) and in the SwiftPM `BlockEngine` module. App code does **not** `import BlockEngine`. It is all one module in the app.

## Rules (Classic)

- The board is 8×8.
- The tray holds **3 pieces**. All 3 must be placed, in any order, before the next 3 are dealt. Pieces **never rotate**.
- You place a piece by dragging it onto empty cells. After each placement, every full **row and column** clears **at the same time**.
- **Game over** happens when no piece left in the tray fits anywhere. There is no revive and no continue.
- **Fairness promise:** at the moment a tray is dealt, there is **always at least one order and placement that fits all 3 pieces**, counting the line clears between them. You can still lose by placing badly. That is the game.

## Scoring (community-measured Block Blast formula, base b = 5)

- **Placement:** +1 point per cell of the placed piece.
- **Line clear:** `L(n) × (C + 1)`.
  - n = lines (rows + cols) cleared by this placement.
  - C = combo *before* this move.
  - L(1)=10, and L(n)=10·n·(n−1) for n≥2. So L(2)=20, L(3)=60, L(4)=120, L(5)=200, L(6)=300. Six is the most lines one piece can complete.
- **Combo / streak** (the iOS rule):
  - A clearing move scores with the current C, then `combo += 1` and `movesSinceClear = 0`.
  - A non-clearing move does `movesSinceClear += 1`. If `movesSinceClear >= 3`, then `combo = 0`. This counts as "comboBroken" only if combo was > 0.
  - So a streak survives **up to 2** non-clearing placements between clears, counted continuously across trays.
- **All Clear** (board fully empty after a clear): +300 flat. The combo does not multiply it.
- **Praise** (by lines in one move):
  - 2 → Good!
  - 3 → Great!
  - 4 → Excellent!
  - 5 → Amazing!
  - 6 → Incredible!
  - Board emptied → Unbelievable! plus "All Clear +300". This takes precedence over the line-count praise.
  - 1 line → no word.
- **"Combo N" banner:** shown when `comboAfter >= 2`.
- **Best score:** tracked by the app layer, **never** passed to the engine or generator.

## Engine API (contract — UI codes against exactly this)

```swift
public enum ShapeCatalog {
    public static let all: [Shape]                       // all 41 orientations
    public static func shape(id: String) -> Shape?
    public static func shapes(in family: PieceFamily) -> [Shape]
}

public enum Scoring {
    public static let comboWindow = 3                    // breaks on the 3rd consecutive non-clearing placement
    public static let allClearBonus = 300
    public static func lineValue(_ lines: Int) -> Int    // L(n)
    public static func clearPoints(lines: Int, comboBefore: Int) -> Int
    public static func praise(lines: Int, boardCleared: Bool) -> Praise?
}

public enum Solver {
    /// True if all shapes can be placed on `occupancy` in SOME order (with line clears applied between placements).
    public static func canPlaceAll(_ shapes: [Shape], on occupancy: UInt64) -> Bool
    /// One concrete solution (order + origins), or nil.
    public static func solve(_ shapes: [Shape], on occupancy: UInt64) -> [(shapeIndex: Int, origin: Cell)]?
}

public enum PieceGenerator {
    public static let version: Int
    /// Deals 3 pieces that are guaranteed placeable on `board` (see GENERATOR.md for `Deal`).
    /// Inputs are ONLY board, this run's score/round, the last two trays, and the run's RNG streams.
    public static func deal(board: Board, score: Int, round: Int, history: [[String]],
                            rng: inout SeededRNG, colorRNG: inout SeededRNG) -> Deal
    /// 0…1 difficulty for a given progress (for the Fair Play page / debugging).
    public static func difficulty(score: Int, round: Int) -> Double
}

public struct GameEngine {
    public private(set) var state: GameState
    public init(seed: UInt64)                 // fresh game, first tray dealt
    public init(restoring state: GameState)   // resume a saved run (no re-deal)
    public func canPlace(trayIndex: Int, at origin: Cell) -> Bool
    public func linesCompleted(trayIndex: Int, at origin: Cell) -> (rows: [Int], cols: [Int])  // preview highlight
    public func isPlaceableAnywhere(trayIndex: Int) -> Bool     // for dimming tray pieces that can't fit
    @discardableResult
    public mutating func place(trayIndex: Int, at origin: Cell) -> MoveOutcome?               // nil if invalid
}
```

`Piece` ids are fresh UUIDs per deal. Colours come from the seeded RNG (uniform over 7, avoiding giving all 3 pieces in a tray the same colour).

## Piece generator

See `GENERATOR.md` (authoritative). Summary:
- The catalog is the 41 Block Blast orientations, including a 1x1 and the 2- and 3-cell diagonals.
- Family weights ramp with this run's score.
- Every tray passes the solvability check, with a fallback ladder that ends in three 1x1s. Three 1x1s always fit, because a board with no full line has an empty cell in every row.
- Early trays favour satisfying clears. That help fades as difficulty rises.
- Inputs are only the board, score, round and RNG.

## Look (default Block Blast skin, pixel-sampled)

- **Background:** vertical gradient #4055B5 (top) → #4B67BF (64%) → #506FC5 (bottom).
- **Board:**
  - Width is about 88–90% of the screen width. Square, centred, with square-ish corners (radius ≤ 6).
  - Frame 4–6 pt, #30447A.
  - Empty cell #242C54, gaps 2 pt in #1E264A.
- **Block (bevel tile):** each side's bevel is about 14% of the cell. Top lightest, left slightly lighter than the face, right darker, bottom darkest, with mitred corners. The face has a slight top→bottom gradient and a 1 pt dark outline.

| colour | face    | top     | left    | right   | bottom  |
|--------|---------|---------|---------|---------|---------|
| red    | #E04844 | #FF9D97 | #EA5A55 | #AD302C | #8F2326 |
| orange | #F35D18 | #FEBC96 | #F96A38 | #D64A07 | #AD3300 |
| yellow | #F5BF06 | #FCF17C | #FACC26 | #DB9C00 | #BD7400 |
| green  | #22C72E | #7FF6A0 | #2AD93A | #109A29 | #007A25 |
| cyan   | #1AC4F0 | #95F3FF | #3FD0F5 | #009FDE | #0074B4 |
| blue   | #3660EF | #8ABFFF | #416DFA | #2450D7 | #1E389E |
| purple | #9252E3 | #E298F7 | #B765F0 | #7936AF | #5F228F |

- **HUD (top):**
  - Gold crown (#F8C010) with the **best** score in bold yellow (#F8E000) and a drop shadow, top-left.
  - Light-blue gear (#B8E0F0), top-right.
  - The current **score**, centred about 15% down: large white heavy rounded font (`.system(size:…, weight: .heavy, design: .rounded)`) with a dark drop shadow. It counts up over about 0.6–1.0 s after points are gained.
  - When a combo streak is active (combo ≥ 2), a small pulsing "Combo N" chip or heart sits by the score.
- **Tray:** three equal slots under the board, at about 74–77% of the screen height. Pieces are drawn at **0.6×** board-cell size and centred in their slot. A piece that cannot fit anywhere right now is drawn dimmed (about 35% opacity). That is an honest hint, unlike the original.
- **Dragging:**
  - Touching a tray piece lifts it. It animates to **1.0× board-cell size** and floats **above the finger**: the piece's bottom edge sits about 1 cell plus 30 pt above the touch point, so the finger never covers it.
  - The piece casts a soft shadow in its own colour.
  - The landing spot snaps to the nearest grid origin, worked out from the floating piece's top-left. It shows each cell as a translucent white fill (about 18%) with a crisp near-white outline.
  - Every row or column that **would clear** is highlighted *before* the drop: the existing blocks in those lines take on the dragged piece's colour **and** get a bright white glow outline, so colour is never the only cue.
  - Dropping on an invalid spot animates the piece back to its tray slot (spring, about 0.25 s) with a soft "nope" sound. There is no penalty.
  - The tray slot stays empty while you hold its piece.
- **Clear effect:**
  - Cleared cells flash white, then shrink and fade over about 0.35 s, staggered outward from the drop point.
  - Shard particles fly in the cell's colour, plus a short bright glow sweeping along each cleared line.
  - A "+N" popup floats up from the cleared area.
  - The praise word pops in (spring scale 0.6 → 1.1 → 1.0) centred over the board, then fades. Unbelievable gets rainbow-gradient text.
  - "Combo N" shows in chunky italic white with a big yellow number.
- **No Space Left:** a dark translucent navy band over the tray reads "No Space Left" for about 1.2 s. The unplaceable pieces show dimmed. Then the game-over card appears.
- **Game over card:**
  - Blue gradient card showing "Score" with the big number, "Best" with the gold number, and a big green **Play Again** button.
  - A new best gets a purple gradient, a gold crown, confetti and "New Best!". Neutral copy only: no "so close", no "X points from your best".
  - Also shows small stats (lines, best combo, pieces placed) and the run's seed.
- **Settings sheet:**
  - Toggles for Sound, Vibration and Reduce Effects (fewer particles, no shake, shorter animations).
  - A "New Game" button with a confirmation.
  - A "Fair Play promise" page.
  - Stats: games played, best score, best combo, total lines.
  - Version.
  - No ads, IAP, accounts, notifications, analytics, tracking or network.
- **Fair Play page:** explains in plain language that:
  - every set of 3 can always be placed;
  - difficulty rises only with this game's score;
  - the game never looks at your best score, your history or your play time;
  - there are no ads, revives or purchases;
  - the exact scoring rules (formula) are as written above;
  - the seed is shown on the game-over screen.

## Feel

- **Haptics:**
  - Light impact on pick-up.
  - Soft/medium impact on a valid drop.
  - Rigid or heavier impact on a clear, scaling with lines.
  - Success notification on All Clear and New Best.
  - Gentle warning on game over.
  - Never on every frame. Persisted toggle.
- **Sound:** synthesised in code (no asset files), via an AVAudioSession `.ambient` category. That respects the silent switch and mixes with her music.
  - Pick-up tick.
  - Placement "plink".
  - Clear chime whose pitch rises with combo level.
  - Bigger arpeggio for 3+ lines.
  - Sparkle for All Clear.
  - Soft fanfare for New Best.
  - Low soft descending tone for game over.
  - Soft thud for an invalid drop.
  - Persisted toggle.
- **Persistence:** the full `GameState` is saved as JSON in Application Support after **every** move and on backgrounding. A run resumes exactly, including the combo. Best score and stats are saved separately. Settings live in UserDefaults.
- **Accessibility:**
  - Line-clear highlights don't rely on colour alone.
  - Dynamic Type isn't needed for the board, but the menus should respect it.
  - VoiceOver labels on the HUD and buttons.
  - Reduce Effects follows the system Reduce Motion setting by default.

## Explicitly excluded (dark patterns)

- No ads of any kind.
- No revive or continue, no piece refresh, no boosters, no currencies, no IAP.
- No tracking or analytics, and no network.
- No notifications.
- No streaks, login rewards or timers.
- No "you're X away from your best" or other near-miss copy.
- No difficulty that depends on best score, losses, play time or engagement.
- No auto-start of the next game.
- No forced theme changes or sensory overload: effects are tasteful and can be reduced.
- No pre-filled "scripted" boards.
