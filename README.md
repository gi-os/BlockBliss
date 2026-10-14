# Block Bliss

An honest 8×8 block puzzle for iPhone. It plays like *Block Blast!* Classic: the same rules, scoring, combos, look and rising difficulty. It has none of the manipulation.

## How it plays

- **Board and pieces.** The board is 8×8. You get three pieces at a time and must place all three before the next three arrive. Pieces never rotate.
- **Clearing.** Full rows and full columns clear at the same time.
- **Game over.** The game ends when none of the pieces left in your tray fit. There is no revive and no "watch an ad to continue".
- **Every set can be placed.** When three pieces are dealt, there is always at least one order and set of positions that fits all three, counting the line clears between them. The engine proves it with a solver before dealing. You can still lose by placing badly, and that is the game.
- **Rising difficulty.** Difficulty rises only with *this game's* progress (rounds and score): bigger, more awkward pieces appear and the early help fades. See [GENERATOR.md](GENERATOR.md).

### Scoring

This is the community-measured Block Blast formula.

| | points |
|---|---|
| Placing a piece | 1 per cell |
| Clearing *n* lines in one move | L(n) × (combo + 1), with L = 10, 20, 60, 120, 200, 300 for n = 1…6 |
| Board fully cleared ("All Clear") | +300 |

**Combo.** The combo grows by 1 with each clearing move. It survives up to two non-clearing placements in a row, and the third one breaks it.

**Praise.**
- 2 lines: Good!
- 3 lines: Great!
- 4 lines: Excellent!
- 5 lines: Amazing!
- 6 lines: Incredible!
- All Clear: Unbelievable!

## Fair Play promise

- No ads, purchases, accounts, tracking, analytics or network access. The app never goes online.
- No revives, boosters, currencies, lives, timers, daily streaks or notifications.
- The piece generator **never** sees your best score, past games, play time or anything about you. Its inputs are only the board, this game's score and round, the last two sets, and the game's seed.
- No "so close to your best!" pressure copy. The game-over screen is neutral and never starts another game for you.
- Each game's seed is shown at game over, so any run can be reproduced.
- Effects can be reduced in Settings, and the game follows the system Reduce Motion setting.

## Project

```
BlockBliss/Engine/   pure-Swift game engine (rules, scoring, solver, generator) — shared with the SwiftPM package
BlockBliss/Game/     view model, persistence, settings, synthesized sound, haptics
BlockBliss/Views/    SwiftUI
Tests/               engine unit tests (swift test)
Tools/blocksim/      Monte-Carlo simulator: plays thousands of games with a bot and checks every deal was solvable
project.yml          xcodegen spec (the .xcodeproj is generated, not committed)
```

```bash
xcodegen generate && open BlockBliss.xcodeproj
```

```bash
swift test
```

```bash
swift run -c release blocksim --games 2000
```

## CI / TestFlight

This uses the same pipeline as the other gi-os iOS apps: fastlane `ship` with `match`. The shared Fastfile is in `fastlane/` and the per-app values are in `ci/app.env`.

- **Check** runs on every branch except `main`. It runs the engine tests and the solvability simulation, then builds unsigned.
- **TestFlight** runs on every push to `main` and on the 1st of each month, because TestFlight builds expire after 90 days. It runs the same checks, then signs and uploads to TestFlight.

The TestFlight upload needs, once per repo:

1. These repository secrets (the same values as the other apps): `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `MATCH_PASSWORD`, `MATCH_GIT_AUTH`.
2. The App Store Connect app record for `com.gios.blockbliss`: My Apps → + → New App. The workflow registers the bundle ID itself, and it fails with a clear message if the record is missing.

Without the secrets, the workflow still tests and compiles, and it lists what's missing.
