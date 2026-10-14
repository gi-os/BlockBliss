# Piece generator — authoritative spec

The design below was prototyped and measured in a throwaway Swift harness before implementation; the shipped code is `BlockBliss/Engine/PieceGenerator.swift` + `Solver.swift`, and `Tools/blocksim` reproduces the measurements.

## Amendments for Block Bliss (these override the design text below)

1. **API** (engine-internal; the UI only calls `difficulty`):
   ```swift
   public struct Deal: Sendable {
       public let pieces: [Piece]          // exactly 3
       public let fallbackLevel: Int       // 0 = normal, 1 = friendly redraw, 2 = easy pool, 3 = fixed ladder, 4 = three singles
       public let nodesSearched: Int
       public let witness: [(slot: Int, origin: Cell)]   // a proof the tray is placeable (order + origins)
   }
   public enum PieceGenerator {
       public static let version = 1
       public static func deal(board: Board, score: Int, round: Int, history: [[String]],
                               rng: inout SeededRNG, colorRNG: inout SeededRNG) -> Deal
       public static func difficulty(score: Int, round: Int) -> Double   // 0...1
   }
   ```
   `GameState` already has `rng`, `colorRNG` and `trayHistory` (last two trays' shape ids, most recent last) — GameEngine passes/updates them. `round` passed to `deal` = trays dealt so far (0 for the first deal).
2. **Shape ids & families:** use the pose names from the catalog table as `Shape.id` (`single`, `domino_h`, … `diag3_anti`). Family mapping to our `PieceFamily`: single→.single, domino→.line2, tri→.line3, quad→.line4, penta→.line5, sq2→.square2, sq3→.square3, rect→.rect2x3, corner3→.corner3, l4→.lShape4, bigL→.corner5, t→.tShape, sz→.sShape, diag2→.diagonal2, diag3→.diagonal3.
3. **Progress scale:** our scoring (SPEC.md) has the combo multiplier `L(n)×(C+1)`, so score grows faster than the prototype's reference scoring. Keep `P = max(rounds, score / S)` but calibrate `S` with blocksim under OUR scoring so that for the greedy bot the median `score/S ≈ rounds` around round 60 (i.e. score only *accelerates* the ramp for strong combo play). Document the value in the Tuning log.
4. **Colours:** drawn from `colorRNG` only; uniform over the 7 colours, no repeated colour within one tray.
5. **Solver:** the public `Solver.canPlaceAll/solve` (SPEC API) is unbounded and exact (used by tests and the engine). The generator uses the same DFS with the node caps/budgets described below (budget by node count, never time). Tests must cross-check generator trays with a *separately written* naive solver in the test target.
6. **Debug check:** in `#if DEBUG`, after each deal replay the witness on a copy of the board via `Board.place` and `assert` it succeeds. Never crash in release.
7. **Determinism:** never iterate `Set`/`Dictionary` in the generator; same seed + same moves ⇒ same trays.

---


I prototyped this in Swift and ran it, so the numbers below are measured, not estimated. The reference code is at the prototype and the simulation harness is at its harness. Everything in the spec was run except where marked.

## 0. Measured results

- **Catalog:** 15 families, 41 poses, 1,767 precomputed placement masks.
- **Deal cost:** about 0.1–0.7 ms on average, with a worst of about 5 ms over about 60k deals on an Apple Silicon Mac at `-O`. Stress boards peaked at 1.4 ms.
- **Soundness:** every dealt tray was re-verified by an independent unbounded solver. Zero unsolvable trays in about 60k game deals and about 8k adversarial boards.
- **Determinism:** the same seed gives the same tray hash, and a different seed gives a different one.
- **Candidate rejection:** unsolvable candidates are 0.004% at d=0 and 6.3% at d=1.
- **Fallback use:**
  - Greedy-bot games: L1 on about 0.17% of deals at d=1, and L2/L3 never.
  - Random stable boards: L1 on 4.4%.
  - Worst-case 8-empty permutation boards: L2 on 3% and L3 on 0.7%. The ladder always produced a verified tray.
- **Greedy bot** (picks the best full-tray order, one-ply board evaluation) at a fixed difficulty, from an empty board, capped at 300 rounds:

| d | avg rounds survived |
|---|---|
| 0.0 | 300 (never died) |
| 0.25 | 292 |
| 0.5 | 233 |
| 0.75 | 145 |
| 1.0 | 117 (min 6) |

- **Under the progress ramp:** the greedy bot averaged about 140–150 rounds.
- **Smart bot** (exhaustive over the tray, evaluates the final board): 160 of 160 rounds in 3 of 3 games.
- **Random bot:** about 5 rounds.
- **Score rate:** a greedy bot averages 32 points per round under the reference scoring (1 point per cell plus 10·L² per clearing placement).
- **Treat the weight tables as v1 calibration.** Real Block Blast frequencies are unpublished, so tune from playtests.

## 1. Fairness contract (what the generator may see)

The generator is a pure function:

`deal(board, rounds, score, recentTrays[2], rngState) -> (tray[3], witness)`

- **Allowed inputs:** the current board, progress (rounds dealt and score), the last two trays (for repetition control), and the RNG state.
- **Forbidden inputs, by signature so they cannot leak in:**
  - high score or proximity to it
  - wall-clock or session length
  - loss, streak or revive history
  - ads, purchases or engagement
  - device or network state
  - remote config or A/B buckets
- **Local and identical everywhere:** the weight tables ship in the binary. Nothing is fetched.
- **The only board-aware parts, both disclosed:**
  - the solvability filter, which is the promise
  - the helpfulness pick, which fades to zero at d=1 and is never negative
- **No adversarial selection.** The generator never prefers trays that are harder on this board. All hardness comes from the board-independent weights.
- **Persistence:** save the current tray, board and RNG state. On relaunch, never re-deal (no scumming, no re-rolling).
- **Opening:** the empty board and an ordinary friendly deal. There is no scripted opening and no pre-filled board.
- **Colors:** use a separate RNG stream. Pick a random color from the 7 default colors per piece, with no repeats inside a tray. Color is independent of shape, so it cannot perturb piece determinism.

## 2. Board and catalog

**Board.** A `UInt64` bitboard where bit = `r*8 + c`, with row 0 at the top. A placement is a precomputed `UInt64` mask per (pose, anchor). A pose with bounding box h×w has `(9-h)*(9-w)` placements.

**Line clear.** Rows and columns are detected on the board after placement, and the union is cleared at once:

```swift
let rowBits: UInt64 = 0x0101010101010101
@inline(__always) func clearLines(_ b: UInt64) -> (UInt64, Int) {
    var x = b & (b >> 1); x &= x >> 2; x &= x >> 4
    let rows = x & rowBits                       // bit 8r set iff row r is full
    var c = b & (b >> 8); c &= c >> 16; c &= c >> 32
    let cols = c & 0xFF                          // bit c set iff column c is full
    let n = rows.nonzeroBitCount + cols.nonzeroBitCount
    if n == 0 { return (b, 0) }
    return (b & ~((rows &* 0xFF) | (cols &* rowBits)), n)
}
```

**Catalog.** There are 41 poses in 15 families, with no rotation: each orientation is its own pose. Cells are `(row,col)`, normalized to the top-left of the bounding box. This matches the real-game bot's 41-pose table, including the 1x1.

| id | pose | cells |
|---|---|---|
| **single (1 pose)** | | |
| 0 | single | (0,0) |
| **domino (2)** | | |
| 1 | domino_h | (0,0)(0,1) |
| 2 | domino_v | (0,0)(1,0) |
| **tri (2)** | | |
| 3 | tri_h | (0,0)(0,1)(0,2) |
| 4 | tri_v | (0,0)(1,0)(2,0) |
| **quad (2)** | | |
| 5 | quad_h | (0,0)(0,1)(0,2)(0,3) |
| 6 | quad_v | (0,0)(1,0)(2,0)(3,0) |
| **penta (2)** | | |
| 7 | penta_h | (0,0)(0,1)(0,2)(0,3)(0,4) |
| 8 | penta_v | (0,0)(1,0)(2,0)(3,0)(4,0) |
| **sq2 (1)** | | |
| 9 | sq2 | (0,0)(0,1)(1,0)(1,1) |
| **sq3 (1)** | | |
| 10 | sq3 | (0,0)(0,1)(0,2)(1,0)(1,1)(1,2)(2,0)(2,1)(2,2) |
| **rect (2)** | | |
| 11 | rect_2x3 | (0,0)(0,1)(0,2)(1,0)(1,1)(1,2) |
| 12 | rect_3x2 | (0,0)(0,1)(1,0)(1,1)(2,0)(2,1) |
| **corner3, the small L (4)** | | |
| 13 | corner_nw | (0,0)(0,1)(1,0) |
| 14 | corner_ne | (0,0)(0,1)(1,1) |
| 15 | corner_sw | (0,0)(1,0)(1,1) |
| 16 | corner_se | (0,1)(1,0)(1,1) |
| **l4, the L/J (8)** | | |
| 17 | l4_a | (0,0)(1,0)(1,1)(1,2) |
| 18 | l4_b | (0,2)(1,0)(1,1)(1,2) |
| 19 | l4_c | (0,0)(0,1)(0,2)(1,0) |
| 20 | l4_d | (0,0)(0,1)(0,2)(1,2) |
| 21 | l4_e | (0,0)(1,0)(2,0)(2,1) |
| 22 | l4_f | (0,1)(1,1)(2,0)(2,1) |
| 23 | l4_g | (0,0)(0,1)(1,0)(2,0) |
| 24 | l4_h | (0,0)(0,1)(1,1)(2,1) |
| **bigL, the 3x3 corner (4)** | | |
| 25 | bigL_nw | (0,0)(0,1)(0,2)(1,0)(2,0) |
| 26 | bigL_ne | (0,0)(0,1)(0,2)(1,2)(2,2) |
| 27 | bigL_sw | (0,0)(1,0)(2,0)(2,1)(2,2) |
| 28 | bigL_se | (0,2)(1,2)(2,0)(2,1)(2,2) |
| **t (4)** | | |
| 29 | t_up | (0,0)(0,1)(0,2)(1,1) |
| 30 | t_down | (0,1)(1,0)(1,1)(1,2) |
| 31 | t_right | (0,0)(1,0)(1,1)(2,0) |
| 32 | t_left | (0,1)(1,0)(1,1)(2,1) |
| **sz (4)** | | |
| 33 | s_h | (0,1)(0,2)(1,0)(1,1) |
| 34 | z_h | (0,0)(0,1)(1,1)(1,2) |
| 35 | z_v | (0,0)(1,0)(1,1)(2,1) |
| 36 | s_v | (0,1)(1,0)(1,1)(2,0) |
| **diag2 (2)** | | |
| 37 | diag2_main | (0,0)(1,1) |
| 38 | diag2_anti | (0,1)(1,0) |
| **diag3 (2)** | | |
| 39 | diag3_main | (0,0)(1,1)(2,2) |
| 40 | diag3_anti | (0,2)(1,1)(2,0) |

"Heavy" means 5 or more cells: penta, sq3, rect and bigL.

## 3. Solvability search

**Definition.** A tray is solvable on board B if some ordering of the 3 pieces and some legal anchors place all three, with clears applied after every placement. Clears can free room for later pieces, so the search must simulate them.

**Algorithm.** It is a DFS with a failure memo and an early exit that returns a witness (the sequence of piece slot and mask).

```swift
// state: (board, remMask: 3 bits). Memo stores FAILURES only, keyed by (board, remMask).
func feasible(_ b: UInt64, _ rem: UInt8, _ wit: inout [(slot: Int, mask: UInt64)]) -> Bool {
    if rem == 0 { return true }
    if memo.hasFailure(b, rem) { return false }
    nodes += 1; if nodes > cap { aborted = true; return false }   // abort = "not proven" = reject
    let last = rem & (rem - 1) == 0
    var tried: [Int] = []
    for i in 0..<3 where rem & (1 << i) != 0 {
        let pid = tray[i]
        if tried.contains(pid) { continue }                        // identical poses: symmetric
        tried.append(pid)
        for m in poses[pid].placements where b & m == 0 {
            wit.append((i, m))
            if last { return true }                                // leaf: existence only
            let (nb, _) = clearLines(b | m)
            if feasible(nb, rem & ~(1 << i), &wit) { return true }
            wit.removeLast()
            if aborted { return false }
        }
    }
    memo.putFailure(b, rem); return false
}
```

**Pruning.**
1. **Leaf existence.** When one piece remains, only check that some placement fits. This cuts a factor of up to 64.
2. **Failure memo** on `(board, remMask)`.
   - It merges the 6 orderings, since placing A then B and B then A often reach the same board.
   - It also merges different anchors that clear to the same board.
   - Use open addressing with a generation counter (32k slots, allocated once, no per-query clear).
3. **Identical-pose symmetry.** Skip a pose already tried at the node.
4. **Early exit on the first witness.** Boards with room succeed in about 3 nodes.

**Soundness rule.** If the node cap is hit before a witness is found, the candidate is rejected, not dealt. A tray is dealt only with a proof in hand.
- Per-candidate cap: 4,000 nodes.
- Per-deal budget: 12,000 nodes, checked before each candidate.
- Budgets count nodes, never wall-clock, so seeds reproduce exactly.

**Complexity.**
- Worst case: at most 6·P₁·P₂ interior states plus P₃ for the leaf scan, where P is the placements per piece and P ≤ 64. That is under 0.4M placement tests for typical shapes, and about 1.6M if all three pieces were 1x1, which is trivial.
- Memoization and early exit make the observed cost orders of magnitude lower.
- Worst observed was 1,841 nodes per deal.

**Debug check.** After every deal, replay the witness through the real engine, which is an independent code path. After every placement, `assert(clearLines(board).1 == 0)`.

## 4. The guarantee, its limits, and the 1x1 decision

**What is guaranteed.** At deal time a full solution exists. It is not guaranteed that the player finds it.
- Placing badly can strand the remaining pieces. Game over is the existing rule: no remaining piece fits.
- This is fair, and it is how the game ends.
- A tray unwinnable only because of the player's earlier placement is the player's loss, not the generator's.
- Optional UX: a "show a solution" hint using the stored witness, off by default.

**Corollary.** A player who always plays a completion that works never loses, since every deal is solvable. The endgame pressure is therefore planning difficulty (awkward pieces), not forced losses. The smart bot's 160 of 160 rounds confirms this.

**Lemma A (stable boards have at least 8 empty cells).**
1. The engine clears every full line after each placement.
2. So on any reachable board no row is full.
3. Each of the 8 rows therefore contains at least one empty cell, so there are at least 8 empty cells.
4. The empty starting board also satisfies this.

**Lemma B (three singles always fit).** Any three of the at least 8 empty cells accept [1x1, 1x1, 1x1] with no clears needed.

**Consequences.**
- With a 1x1 in the catalog, a solvable tray exists on every reachable board, unconditionally.
- No induction over previous trays is needed, so "the previous tray was solvable and placed" is irrelevant.
- The ladder's last rung needs no search, so the generator cannot fail or deadlock. This includes the first deal.

**Why the 1x1 must be in the catalog.** Without it the claim is false for some stable boards.
- Take 8 empties forming a permutation pattern (one per row and column, none touching orthogonally or diagonally). Only a 1x1 can be placed.
- Of 3,000 random permutation boards, 385 had this property.
- I did not prove such a board is reachable in real play. It does not matter, because the 1x1 makes the question moot.

**1x1 decision: include it.**
- It is in the real-game bot's 41-pose table, though I could not confirm it visually.
- It gives the unconditional guarantee.
- Its natural weight is tiny: 0.3–1.0 out of about 90–100 at d=1 and d=0, so it is a rare lucky piece.
- A tray of three singles appears only as the last ladder rung (see §7).

**Deciding "what is solvable".** Use only trays with a witness, never "probably".

## 5. Difficulty ramp

**Progress and difficulty.**

```
P = max(rounds, score / 40.0)        // rounds = trays dealt so far; score/40 only accelerates combo-heavy play
d = piecewiseLinear(P, [(0,0), (10,0.15), (30,0.4), (60,0.65), (100,0.85), (150,1.0)])
```

- The 40 matches the reference scoring: about 32 points per round for a greedy bot.
- If your scoring differs, rescale the constant so typical score/40 is about equal to rounds.

**Family weights.** Linear interpolation between the anchors at d = 0, .25, .5, .75, 1. The per-pose weight is the family weight divided by the family's pose count.

| family | d=0 | .25 | .5 | .75 | 1 |
|---|---|---|---|---|---|
| single | 1 | 0.8 | 0.6 | 0.4 | 0.3 |
| domino | 10 | 7 | 4 | 2.5 | 1.5 |
| tri | 14 | 11 | 8 | 5 | 3.5 |
| quad | 6 | 7 | 8 | 8 | 8 |
| penta | 2 | 4 | 7 | 9.5 | 12 |
| sq2 | 14 | 12 | 10 | 8 | 7 |
| sq3 | 1 | 3 | 5 | 7 | 9 |
| rect | 4 | 6 | 8 | 10 | 12 |
| corner3 | 14 | 12 | 9 | 6 | 4 |
| l4 | 9 | 10 | 11 | 12.5 | 14 |
| bigL | 1 | 3 | 5 | 7 | 9 |
| t | 5 | 5.5 | 6 | 6.5 | 7 |
| sz | 3 | 4 | 6 | 8 | 10 |
| diag2 | 4 | 4 | 3 | 2 | 1.5 |
| diag3 | 1 | 1.5 | 2 | 2 | 2 |

**Resulting piece-set statistics.**

| d | total weight | avg cells per piece | heavy share |
|---|---|---|---|
| 0.00 | 89.0 | 3.51 | 9.0% |
| 0.25 | 90.8 | 3.84 | 17.6% |
| 0.50 | 92.6 | 4.20 | 27.0% |
| 0.75 | 94.4 | 4.51 | 35.5% |
| 1.00 | 100.8 | 4.73 | 41.7% |

Measured average tray size is about 11 cells at d≈0 and about 13.7 at d≈1.

**Tray caps (hard rules in candidate sampling).**
- `maxHeavy(d)` is 1 if d<0.25, 2 if d<0.9, and 3 otherwise.
- `maxSq3(d)` is 1 if d<0.8, and 2 otherwise.
- Sampling zeroes the weight of poses that would violate a cap.

## 6. Repetition control

**Candidate sampling.** Draw 3 poses sequentially. For each pose p, start from `w[p]` and apply these multipliers:

- **History:** ×0.5 if p was in the previous tray, else ×0.75 if it was in the tray before that.
- **Same family already in this tray:** ×0.35, and weight 0 if two are already present. Hence no three of one family, except in fallback.
- **Same pose already in this tray:** an extra ×0.4.
- **Caps:** apply the caps above.

Then shuffle the slot order. Reject a candidate whose sorted pose multiset equals the previous tray's, or one already seen this deal.

**Relaxed mode** (used only by L1): forbid only a third identical pose.

**Measured result:** a tray containing the same pose twice occurs in about 1–3% of deals. "Intentional" duplicates exist in only that form.

## 7. Helpfulness, and the deal algorithm

**Helpfulness of a candidate tray T on board B** (depth-2 lookahead, cheap):
- `lines`: the maximum lines cleared over every single placement and every ordered pair of distinct slots.
- `steps`: how many of those placements clear anything (0–2).
- `p1`: how many of the 3 pieces have a placement that clears a line right now.

```
h = 0.45*min(lines,4)/4 + 0.25*min(steps,2)/2 + 0.30*p1/3     // h in [0,1]
```

**Selection among solvable candidates.**
- `pHelp(d) = 0.7*(1-d)^2`. This is 0.7 at d=0, 0.175 at d=0.5, 0.04 at d=0.75, and exactly 0 at d=1.
- With probability pHelp, pick the highest-h candidate, with random tie-break.
- Otherwise pick uniformly at random.
- The boost is bounded (at most 70% of deals), progress-only and never negative.
- Measured chosen versus mean candidate h:

| difficulty bucket | chosen h | mean candidate h |
|---|---|---|
| d≈0 | 0.385 | 0.281 |
| mid | 0.417 | 0.359 |
| late | no difference | no difference |

**Candidate count.** `K(d) = round(24 - 16d)`. Try up to 3K draws to collect K distinct candidates.

**Deal pseudocode.**

```
deal(board, rounds, score):
  d = difficulty(rounds, score); spent = 0
  // L0: normal
  cands = []
  for up to K(d) distinct sampled trays t (weights w(d), caps(d), repetition rules):
      if spent > 12_000 { break }
      cap = 4000; ok = feasible(board, 0b111); spent += nodes
      if ok { cands.append((t, helpfulness(t, board))) }
  if cands nonempty: pick per pHelp(d) rule; update history; return
  // L1: friendly redraw
  same as L0 but w(0), caps(0), relaxed dups, K=64, no helpfulness boost
  // L2: easy-pool sampling
  pool = {single, domino, tri, corner3, sq2, diag2} with w(0)
  for up to 48 draws of 3 poses (skip three-identical):
      cap 2000; if feasible: shuffle slots; return
  // L3: fixed ladder, each checked with cap 2000
  for t in [[corner_nw, domino_h, single], [domino_h, domino_h, single], [domino_h, single, single]]:
      if feasible: return t
  return [single, single, single]      // unconditionally valid by Lemma B
```

**Is the fallback ladder fair?** Yes. It is the disclosed promise, board-aware only to keep the game playable, and it triggers rarely. Log it locally for QA only, with no analytics.

## 8. RNG and determinism

Use SplitMix64 as a `RandomNumberGenerator` (seed in, state out):

```swift
struct SplitMix64: RandomNumberGenerator {
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
```

Rules to keep seeds reproducible:
- Never iterate a Swift `Set` or `Dictionary`. Their order changes between processes. Use arrays, and use dictionaries for lookup only.
- Budget by node count, never by time.
- Accumulate floating-point weights in a fixed order.
- Pin tests to one platform, or use integer weights, because `exp`/`pow` can differ slightly across platforms (this design uses only multiplication).
- Persist the RNG state, history and current tray in saves.

## 9. Acceptance tests

1. **Soundness fuzz.** Over many seeds and boards, verify every dealt tray with an independent unbounded solver. The prototype did this with zero failures.
2. **Lemmas.** After every engine step, assert no full line and at least 8 empty cells. On permutation boards, `deal` must always return a verified tray.
3. **Determinism.** The same seed gives the same sequence, and a different seed gives a different one.
4. **Purity.** The compiler-visible signature has none of the forbidden inputs from §1.
5. **Perf.** The 99.9th percentile of `deal` stays under 5 ms on the target device. The prototype worst was about 5 ms on a Mac, so budget the device separately.
6. **Distribution.** Check average tray cells by d, the heavy share, the duplicate rate, and that no tray has three same-family pieces outside fallback.
7. **Fallback rates** on bot games: L1 about 0.2% at d=1, and L2/L3 about 0.

## 10. Tuning notes and caveats

- **Weights are guesses.** Real Block Blast frequencies are unpublished, so the table is a starting point. Playtest and adjust: for example, raise penta/sq3/bigL/sz at d=1 if experts survive too long.
- **Ramp length.** The ramp reaches d=1 at 150 rounds. Shorten or lengthen the progress anchors to taste.
- **A perfect player never loses** under this guarantee. If that is undesirable, the lever is more awkward piece weights. Do not use board-aware adversarial selection, which would break the fairness contract.
- **Diagonals.** Diagonal pieces are medium confidence in the research (seen in 2026 builds, absent from older guides). They can be dropped from the catalog by zeroing diag2/diag3. Lemma B is unaffected.
- **Tray size.** I used 3 pieces per tray. The Tencent "4 pieces" claim contradicts the footage and the other sources.

## Tuning log

### v1 (generator `version = 1`), engine agent

All constants live in `PieceGenerator.Tuning` (`BlockBliss/Engine/PieceGenerator.swift`). Measured with
`swift run -c release blocksim --games 2000` (seed 1; greedy bot = tries every order of the tray, places each piece
for lines cleared then board smoothness / fewest walled-in holes, no combo awareness).

**Constants changed from the design text above**

| constant | design | now | why |
|---|---|---|---|
| `scorePerRound` S | 40 | **95** | Our scoring (`L(n)·(C+1)`) pays far more per round than the prototype's reference scoring. With S=40 the score term ran the ramp: the greedy bot's median score/40 implied d≈0.8 at round 40 and d=1 by round 60. With S=95 the median greedy score at round 60 is 5,668 (94.5 points/round), so `score/S ≈ rounds` at round 60, and score only accelerates the ramp for strong combo play (median score/S is 127 at round 100 and 235 at round 150). |
| progress anchors | (0,0) (10,.15) (30,.4) (60,.65) (100,.85) (150,1) | (0,0) (10,.15) **(25,.4) (50,.7) (80,.9) (110,1)** | The ramp now tops out at round 110, so games reliably end. d at round 10 is unchanged, so the opening is as generous as designed. |
| family weights, d = 1 column only | single .3, domino 1.5, tri 3.5, penta 12, sq2 7, sq3 9, rect 12, corner3 4, bigL 9, t 7, sz 10, diag2 1.5 | single **.2**, domino **1.0**, tri **2.5**, penta **14**, sq2 **6**, sq3 **11**, rect **13**, corner3 **3**, bigL **11**, t **8**, sz **12**, diag2 **1.0** | The §10 lever ("raise penta/sq3/bigL/sz at d=1 if experts survive too long"). Avg cells/piece at d=1: 4.73 -> 4.88, heavy share 41.7% -> 45.9%. The d = 0, .25, .5, .75 columns are untouched (same opening and mid-game as the design). |

Everything else is as designed: K(d) = round(24-16d), pHelp = 0.7(1-d)², heavy / sq3 caps, repetition multipliers
(.5 / .75 / .35 / .4), 4,000-node candidate cap, 12,000-node per-level budget, 2,000-node cap and 48 draws in L2/L3.

**Implementation notes (behaviour-neutral or disclosed)**

- `Shape.id` is the pose name (`single`, `domino_h`, ... `diag3_anti`) per Amendment 2, not the `line5.h` style in the `Models.swift` doc comment.
- The pHelp coin is flipped once per deal, before sampling, and helpfulness is only computed when it comes up heads (same distribution as the design, much cheaper).
- L0 and L1 each get their own 12,000-node budget. Level 4 (three singles) is reported separately from level 3 (fixed ladder), as in the `Deal` amendment.
- Colours: exactly three draws from `colorRNG` per deal (all distinct), whatever the fallback level.
- Debug builds replay every witness through `Board.place` and `assert` it.

**Final `blocksim --games 2000 --seed 1` summary (release, Apple Silicon)**

| | greedy bot (2,000 games) | random-ish bot (500 games) |
|---|---|---|
| deals / solvable | 253,022 / **100.000%** | 3,279 / **100.000%** |
| fallback ladder L0 / L1 / L2 / L3 / L4 | 99.913% / 0.087% / 0 / 0 / 0 | 100% / 0 / 0 / 0 / 0 |
| generator CPU ms per deal p50 / p99 / p99.9 / max | 0.057 / 0.903 / 1.312 / 1.541 | 0.147 / 1.327 / 1.405 / 1.424 |
| final score mean / median / p10 / p90 | 18,493 / 14,193 / 4,968 / 38,311 | 124 / 85 / 37 / 248 |
| rounds (trays dealt) mean / median / p10 / p90 / max | 126.5 / **108** / 56 / 220 / 569 | 6.6 / 6 / 4 / 10 / 21 |
| games reaching 1,000 rounds | 0 | 0 |

- Greedy survival: <40 rounds 2.6%, 40-99 41.1%, 100-149 28.8%, 150-249 20.6%, 250+ 6.8%.
- Generator stress (3,000 random stable boards, fill 8-56, every third one an adversarial 8-empty permutation board): 0 unsolvable, levels L0..L4 = 1504 / 1312 / 161 / 23 / 0, worst 1.0 ms CPU.
- `Solver.canPlaceAll`, 30,000 random 3-piece cases: p50 2 us, p99 16 us, worst 0.12 ms; all 729 heavy-piece trays on an empty board: worst 6 us.
- Piece-family share and size by difficulty band (greedy): average cells/piece 3.82 (d<.25), 4.10, 4.32, 4.64 (d>=.75); heavy-piece share 17.1%, 25.2%, 30.8%, 39.9%; same pose twice in a tray 1.4-2.4% of deals.
- A player who always finds a completing order never loses (every deal is solvable by construction), so the ramp "bites" through planning difficulty, not forced losses. Re-tune by shortening the progress anchors or raising the d=1 heavy weights; do not add board-aware selection.


### v2 (2026-10-14) — more board wipes, from playtest feedback ("too hard to do a screen wipe, pieces feel too random")

- **Help schedule:** `helpChance(d) = 0.9 - 0.9·d` (was `0.7·(1-d)²`), so about 54% of deals are help-picked at round 25 instead of about 25%.
- **Perfect-fit chains:** on help deals, 10 extra candidates are built piece by piece (`buildChain`). Each piece is drawn among shapes that can complete a line on the simulated board, weighted `poseWeight·(1+lines²)`, and ×40 if that placement wipes the board. The family, heavy and 3x3 caps still apply. The construction is itself a solution, and every candidate is still proven with the solver.
- **Whole-tray outcome scoring** (`outcomeScore`) replaces the old depth-2 `helpfulness`. It runs a DFS over every order and placement, trying clearing moves first, with a cap of 3,000 nodes. It ranks wipe > lines > emptier board.
- **blocksim, greedy bot, 300 games, seed 7:**

| | All Clears per game | rounds (mean / median / p90) | solvable |
|---|---|---|---|
| v1 | 0.26 | 123 / 103 / 225 | 100% |
| v2 | 1.68 | 153 / 133 / 257 | 100% |

All games still end.
- `PieceGenerator.version` is now 2.
