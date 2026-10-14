import Foundation

/// One dealt tray plus the proof that it is placeable.
public struct Deal: Sendable {
    /// Exactly 3 pieces, in tray order.
    public let pieces: [Piece]
    /// 0 = normal, 1 = friendly redraw, 2 = easy pool, 3 = fixed ladder, 4 = three singles.
    public let fallbackLevel: Int
    /// Search nodes spent proving solvability (a work measure, never wall-clock time).
    public let nodesSearched: Int
    /// A proof the tray is placeable: the order of play (tray slots) with origins.
    public let witness: [(slot: Int, origin: Cell)]
}

/// Deals trays of 3. See GENERATOR.md (authoritative) for the design and the fairness contract.
///
/// The only inputs are the board, this run's score and round, the last two trays (repetition control) and
/// the run's RNG streams. Nothing about the player's best score, history, play time or device can reach it.
/// Every tray is dealt with a proof (witness) that all three pieces can be placed.
public enum PieceGenerator {
    public static let version = 2

    // MARK: Tuning

    /// Every tunable constant lives here; changes are recorded in GENERATOR.md's "Tuning log".
    enum Tuning {
        /// Score points that count as one round of progress: `P = max(round, score / scorePerRound)`.
        static let scorePerRound = 95.0
        /// (progress, difficulty) anchors, piecewise linear.
        static let progressAnchors: [(Double, Double)] = [(0, 0), (10, 0.15), (25, 0.4), (50, 0.7), (80, 0.9), (110, 1.0)]

        /// Difficulty anchors the family weight table is interpolated between.
        static let weightAnchors: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
        /// Family weights at each anchor, in `PieceFamily.allCases` order. A pose's weight is its family's
        /// weight divided by the family's pose count.
        static let familyWeights: [[Double]] = [
            [1.0, 0.8, 0.6, 0.4, 0.2],    // single
            [10, 7, 4, 2.5, 1.0],         // line2
            [14, 11, 8, 5, 2.5],          // line3
            [6, 7, 8, 8, 8],              // line4
            [2, 4, 7, 9.5, 14],           // line5
            [14, 12, 10, 8, 6],           // square2
            [1, 3, 5, 7, 11],             // square3
            [4, 6, 8, 10, 13],            // rect2x3
            [14, 12, 9, 6, 3],            // corner3
            [9, 10, 11, 12.5, 14],        // lShape4
            [1, 3, 5, 7, 11],             // corner5
            [5, 5.5, 6, 6.5, 8],          // tShape
            [3, 4, 6, 8, 12],             // sShape
            [4, 4, 3, 2, 1],              // diagonal2
            [1, 1.5, 2, 2, 2],            // diagonal3
        ]

        static let historyPreviousTrayFactor = 0.5
        static let historyTrayBeforeFactor = 0.75
        static let sameFamilyFactor = 0.35
        static let samePoseFactor = 0.4

        /// Search budgets, counted in nodes so seeds reproduce exactly.
        static let nodeCapPerCandidate = 4_000
        static let nodeBudgetPerLevel = 12_000
        static let easyPoolNodeCap = 2_000
        static let easyPoolDraws = 48
        static let friendlyCandidates = 64

        /// Probability that a deal is a "helpful" pick (the candidate with the best whole-tray outcome on this
        /// board) instead of a uniform one: 90% at the start, fading linearly to 0 at full difficulty. Help only
        /// ever makes the board easier; the late game's challenge comes from the piece weights.
        static let helpEarly = 0.9
        static let helpLate = 0.0
        static func helpChance(_ d: Double) -> Double { helpEarly - (helpEarly - helpLate) * d }
        /// Extra "perfect fit" candidates built piece by piece on helpful deals.
        static let chainCandidates = 10
        /// Placements examined when scoring one candidate's whole-tray outcome.
        static let outcomeNodeCap = 3_000

        static func candidateCount(_ d: Double) -> Int { Int((24 - 16 * d).rounded()) }
        static func maxHeavy(_ d: Double) -> Int { d < 0.25 ? 1 : (d < 0.9 ? 2 : 3) }
        static func maxSquare3(_ d: Double) -> Int { d < 0.8 ? 1 : 2 }
        /// "Heavy" pieces have 5 or more cells.
        static let heavyCells = 5
    }

    // MARK: Difficulty

    /// 0...1 difficulty for a given progress. Depends only on this run's score and round.
    public static func difficulty(score: Int, round: Int) -> Double {
        let progress = max(Double(max(round, 0)), Double(max(score, 0)) / Tuning.scorePerRound)
        return piecewiseLinear(progress, Tuning.progressAnchors)
    }

    // MARK: Dealing

    private typealias Witness = [(slot: Int, origin: Cell)]

    /// Deals 3 pieces that are guaranteed placeable on `board`.
    /// - Parameters:
    ///   - round: trays dealt so far (0 for the first deal).
    ///   - history: shape ids of the last two trays, most recent last.
    public static func deal(board: Board, score: Int, round: Int, history: [[String]],
                            rng: inout SeededRNG, colorRNG: inout SeededRNG) -> Deal {
        let d = difficulty(score: score, round: round)
        var dealer = Dealer(occupancy: board.occupancy)
        let previous = history.last.map(catalogIndices) ?? []
        let beforeThat = history.count >= 2 ? catalogIndices(history[history.count - 2]) : []
        let recency = recencyFactors(previous: previous, beforeThat: beforeThat)

        var chosen: (tray: [Int], witness: Witness, level: Int)?

        // L0 (normal) and L1 (friendly redraw: easiest weights, relaxed duplicate rules, no helpfulness boost).
        let useHelp = rng.nextUnit() < Tuning.helpChance(d)
        for level in 0...1 where chosen == nil {
            var candidates = dealer.gatherCandidates(
                d: level == 0 ? d : 0, relaxed: level == 1,
                count: level == 0 ? Tuning.candidateCount(d) : Tuning.friendlyCandidates,
                previous: previous, recency: recency, rng: &rng)
            if level == 0 && useHelp {
                candidates += dealer.chainCandidates(d: d, recency: recency, previous: previous, rng: &rng)
            }
            if let pick = dealer.select(candidates, preferHelpful: level == 0 && useHelp, rng: &rng) {
                chosen = (pick.tray, pick.witness, level)
            }
        }
        // L2: sampled from an easy pool.
        if chosen == nil, let pick = dealer.easyPoolTray(rng: &rng) {
            chosen = (pick.tray, pick.witness, 2)
        }
        // L3: fixed ladder, each rung checked.
        if chosen == nil, let pick = dealer.fixedLadderTray() {
            chosen = (pick.tray, pick.witness, 3)
        }
        // L4: three singles. Valid unconditionally: a board with no full line has an empty cell in every row.
        let final: (tray: [Int], witness: Witness, level: Int)
        if let chosen {
            final = chosen
        } else {
            let singles = [Int](repeating: single, count: 3)
            final = (singles, dealer.witness(for: singles) ?? [], 4)
        }

        let colors = drawColors(&colorRNG)
        let pieces = final.tray.enumerated().map { Piece(shape: ShapeCatalog.all[$0.element], color: colors[$0.offset]) }
        let result = Deal(pieces: pieces, fallbackLevel: final.level, nodesSearched: dealer.nodes, witness: final.witness)
        #if DEBUG
        verify(result, on: board)
        #endif
        return result
    }

    // MARK: Catalog-derived tables

    private static let catalogCount = ShapeCatalog.all.count
    private static let single = ShapeCatalog.index(ofID: "single")!
    private static let familyOfShape: [Int] = ShapeCatalog.all.map { PieceFamily.allCases.firstIndex(of: $0.family)! }
    private static let cellsOfShape: [Int] = ShapeCatalog.all.map(\.cellCount)
    private static let isSquare3: [Bool] = ShapeCatalog.all.map { $0.family == .square3 }
    private static let posesPerFamily: [Int] = PieceFamily.allCases.map { ShapeCatalog.shapes(in: $0).count }

    private static func catalogIndices(_ ids: [String]) -> [Int] {
        ids.compactMap { ShapeCatalog.index(ofID: $0) }
    }

    /// Per-pose sampling weight at difficulty `d`: the family weight (interpolated) spread over its poses.
    static func poseWeights(d: Double) -> [Double] {
        let family = Tuning.familyWeights.map { piecewiseLinear(d, Array(zip(Tuning.weightAnchors, $0))) }
        return (0..<catalogCount).map { family[familyOfShape[$0]] / Double(posesPerFamily[familyOfShape[$0]]) }
    }

    /// Per-pose multiplier for repetition control: x0.5 if in the previous tray, else x0.75 if in the one before.
    private static func recencyFactors(previous: [Int], beforeThat: [Int]) -> [Double] {
        var factors = [Double](repeating: 1, count: catalogCount)
        for p in previous { factors[p] = Tuning.historyPreviousTrayFactor }
        for p in beforeThat where !previous.contains(p) { factors[p] = Tuning.historyTrayBeforeFactor }
        return factors
    }

    // MARK: Small numeric helpers

    private static func piecewiseLinear(_ x: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        for i in 1..<points.count where x <= points[i].0 {
            let t = (x - points[i - 1].0) / (points[i].0 - points[i - 1].0)
            return points[i - 1].1 + t * (points[i].1 - points[i - 1].1)
        }
        return last.1
    }

    private static func below(_ n: Int, _ rng: inout SeededRNG) -> Int {
        Int(rng.next() % UInt64(n))
    }

    /// Roulette-wheel pick over non-negative weights, accumulated in a fixed order.
    private static func weightedPick(_ weights: [Double], _ rng: inout SeededRNG) -> Int {
        var total = 0.0
        var i = 0
        while i < weights.count { total += weights[i]; i += 1 }
        if total <= 0 { return below(weights.count, &rng) }
        var x = rng.nextUnit() * total
        var lastPositive = 0
        i = 0
        while i < weights.count {
            if weights[i] > 0 {
                x -= weights[i]
                if x < 0 { return i }
                lastPositive = i
            }
            i += 1
        }
        return lastPositive
    }

    private static func shuffle(_ picks: inout [Int], _ rng: inout SeededRNG) {
        for i in stride(from: picks.count - 1, to: 0, by: -1) {
            picks.swapAt(i, below(i + 1, &rng))
        }
    }

    /// Three distinct colours from the colour stream only (always exactly 3 draws, whatever the fallback level).
    private static func drawColors(_ colorRNG: inout SeededRNG) -> [BlockColor] {
        var pool = BlockColor.allCases
        var colors: [BlockColor] = []
        for _ in 0..<3 {
            colors.append(pool.remove(at: below(pool.count, &colorRNG)))
        }
        return colors
    }

    // MARK: Candidate machinery

    private struct Candidate {
        let tray: [Int]
        let witness: Witness
        /// Known outcome score from construction (chain candidates); 0 when unknown.
        var hint = 0
    }

    private struct Dealer {
        let occupancy: UInt64
        var search = TraySearch()
        private(set) var nodes = 0

        init(occupancy: UInt64) { self.occupancy = occupancy }

        /// Proves a tray solvable (or not) within `cap` nodes. Failure includes "cap hit, not proven".
        mutating func witness(for tray: [Int], cap: Int = .max) -> Witness? {
            search.load(tray.map { ShapeCatalog.placementSets[$0] }, nodeCap: cap)
            let solved = search.run(on: occupancy)
            nodes += search.nodes
            return solved ? search.witness : nil
        }

        /// Draws up to `count` distinct trays and keeps those proven solvable.
        mutating func gatherCandidates(d: Double, relaxed: Bool, count: Int, previous: [Int], recency: [Double],
                                       rng: inout SeededRNG) -> [Candidate] {
            let weights = PieceGenerator.poseWeights(d: d)
            let base = (0..<PieceGenerator.catalogCount).map { weights[$0] * recency[$0] }
            let previousKey = previous.sorted()
            var seen: [[Int]] = []
            var candidates: [Candidate] = []
            var attempts = 0
            var spent = 0
            while seen.count < count && attempts < count * 3 {
                attempts += 1
                let tray = PieceGenerator.sampleTray(d: d, base: base, relaxed: relaxed, rng: &rng)
                let key = tray.sorted()
                if key == previousKey || seen.contains(key) { continue }
                seen.append(key)
                if spent > Tuning.nodeBudgetPerLevel { break }
                let before = nodes
                if let proof = witness(for: tray, cap: Tuning.nodeCapPerCandidate) {
                    candidates.append(Candidate(tray: tray, witness: proof))
                }
                spent += nodes - before
            }
            return candidates
        }

        /// Picks uniformly, or (when `preferHelpful`) the candidate with the best whole-tray outcome on this
        /// board — a full board wipe beats everything, then most lines, then the emptiest board — ties random.
        func select(_ candidates: [Candidate], preferHelpful: Bool, rng: inout SeededRNG) -> Candidate? {
            guard !candidates.isEmpty else { return nil }
            var index = PieceGenerator.below(candidates.count, &rng)
            if preferHelpful {
                let scores = candidates.map { max($0.hint, PieceGenerator.outcomeScore($0.tray, occupancy: occupancy)) }
                let best = scores.max()!
                let ties = scores.indices.filter { scores[$0] == best }
                index = ties[PieceGenerator.below(ties.count, &rng)]
            }
            return candidates[index]
        }

        /// "Perfect fit" trays: each piece is drawn among shapes that can complete a row or column on the board
        /// as it will be after the previous pieces, favouring placements that clear more and above all ones that
        /// wipe the board. The construction itself is a solution, so these are always placeable.
        mutating func chainCandidates(d: Double, recency: [Double], previous: [Int], rng: inout SeededRNG) -> [Candidate] {
            let weights = PieceGenerator.poseWeights(d: d)
            let base = (0..<PieceGenerator.catalogCount).map { weights[$0] * recency[$0] }
            let previousKey = previous.sorted()
            var result: [Candidate] = []
            var seen: [[Int]] = []
            for _ in 0..<Tuning.chainCandidates {
                guard let built = PieceGenerator.buildChain(d: d, base: base, occupancy: occupancy, rng: &rng) else { continue }
                let key = built.tray.sorted()
                if key == previousKey || seen.contains(key) { continue }
                seen.append(key)
                if let proof = witness(for: built.tray, cap: Tuning.nodeCapPerCandidate) {
                    result.append(Candidate(tray: built.tray, witness: proof, hint: built.score))
                }
            }
            return result
        }

        mutating func easyPoolTray(rng: inout SeededRNG) -> Candidate? {
            let easy: Set<PieceFamily> = [.single, .line2, .line3, .corner3, .square2, .diagonal2]
            let base = PieceGenerator.poseWeights(d: 0)
            let weights = (0..<PieceGenerator.catalogCount).map { easy.contains(ShapeCatalog.all[$0].family) ? base[$0] : 0 }
            for _ in 0..<Tuning.easyPoolDraws {
                var tray = (0..<3).map { _ in PieceGenerator.weightedPick(weights, &rng) }
                if tray[0] == tray[1] && tray[1] == tray[2] { continue }
                PieceGenerator.shuffle(&tray, &rng)
                if let proof = witness(for: tray, cap: Tuning.easyPoolNodeCap) {
                    return Candidate(tray: tray, witness: proof)
                }
            }
            return nil
        }

        mutating func fixedLadderTray() -> Candidate? {
            let ladder = [["corner_nw", "domino_h", "single"], ["domino_h", "domino_h", "single"], ["domino_h", "single", "single"]]
            for rung in ladder {
                let tray = PieceGenerator.catalogIndices(rung)
                if let proof = witness(for: tray, cap: Tuning.easyPoolNodeCap) {
                    return Candidate(tray: tray, witness: proof)
                }
            }
            return nil
        }
    }

    /// Draws one candidate tray (3 catalog indices, slot order shuffled) under the family, duplicate and cap
    /// rules. `base` already includes the repetition (recency) factors.
    private static func sampleTray(d: Double, base: [Double], relaxed: Bool, rng: inout SeededRNG) -> [Int] {
        var picks: [Int] = []
        var familyCount = [Int](repeating: 0, count: posesPerFamily.count)
        var poseCount = [Int](repeating: 0, count: catalogCount)
        var heavy = 0
        var square3 = 0
        let heavyLimit = Tuning.maxHeavy(d), square3Limit = Tuning.maxSquare3(d)
        var weights = [Double](repeating: 0, count: catalogCount)
        for _ in 0..<3 {
            var p = 0
            while p < catalogCount {
                var w = base[p]
                let sameFamily = familyCount[familyOfShape[p]]
                if relaxed {
                    if poseCount[p] >= 2 { w = 0 }                  // only a third identical pose is forbidden
                } else {
                    if sameFamily >= 2 { w = 0 } else if sameFamily == 1 { w *= Tuning.sameFamilyFactor }
                    if poseCount[p] >= 1 { w *= Tuning.samePoseFactor }
                }
                if cellsOfShape[p] >= Tuning.heavyCells && heavy >= heavyLimit { w = 0 }
                if isSquare3[p] && square3 >= square3Limit { w = 0 }
                weights[p] = w
                p += 1
            }
            let pick = weightedPick(weights, &rng)
            picks.append(pick)
            familyCount[familyOfShape[pick]] += 1
            poseCount[pick] += 1
            if cellsOfShape[pick] >= Tuning.heavyCells { heavy += 1 }
            if isSquare3[pick] { square3 += 1 }
        }
        shuffle(&picks, &rng)
        return picks
    }

    /// Outcome score of one simulated sequence: a board wipe dominates, then lines cleared, then how empty
    /// the board is afterwards.
    private static func outcomeValue(wiped: Bool, lines: Int, board: UInt64) -> Int {
        (wiped ? 10_000 : 0) + lines * 100 + (64 - board.nonzeroBitCount)
    }

    /// Best whole-tray outcome over every order and placement, explored clearing-moves-first within a node
    /// budget (a heuristic score: it only steers which solvable tray a helpful deal offers).
    static func outcomeScore(_ tray: [Int], occupancy: UInt64) -> Int {
        var search = OutcomeSearch(tray: tray)
        search.run(board: occupancy, remaining: 0b111, lines: 0, wiped: false)
        return search.best
    }

    private struct OutcomeSearch {
        let tray: [Int]
        var best = 0
        var nodes = 0

        mutating func run(board: UInt64, remaining: Int, lines: Int, wiped: Bool) {
            if remaining == 0 {
                best = max(best, PieceGenerator.outcomeValue(wiped: wiped, lines: lines, board: board))
                return
            }
            for i in 0..<3 where remaining & (1 << i) != 0 {
                // Identical shapes are interchangeable: only expand the first one still remaining.
                if (0..<i).contains(where: { remaining & (1 << $0) != 0 && tray[$0] == tray[i] }) { continue }
                let masks = ShapeCatalog.placementSets[tray[i]].masks
                for clearingPass in [true, false] {
                    var k = 0
                    while k < masks.count {
                        let m = masks[k]
                        k += 1
                        if board & m != 0 { continue }
                        let (next, cleared) = BoardBits.clearFullLines(board | m)
                        if (cleared > 0) != clearingPass { continue }
                        nodes += 1
                        if nodes > Tuning.outcomeNodeCap { return }
                        run(board: next, remaining: remaining & ~(1 << i), lines: lines + cleared,
                            wiped: wiped || (cleared > 0 && next == 0))
                        if best >= 10_000 { return }            // a wipe is as good as it gets
                    }
                }
            }
        }
    }

    /// Builds one tray piece by piece. Each step looks at every shape allowed by the tray rules and every
    /// placement of it that clears at least one line on the current simulated board, and draws one with
    /// weight `poseWeight * (1 + lines^2)`, x40 if it wipes the board. Steps with no clearing option draw a
    /// normal weighted piece and leave the simulated board as it is. Returns nil if no step could clear.
    fileprivate static func buildChain(d: Double, base: [Double], occupancy: UInt64,
                                       rng: inout SeededRNG) -> (tray: [Int], score: Int)? {
        var board = occupancy
        var tray: [Int] = []
        var familyCount = [Int](repeating: 0, count: posesPerFamily.count)
        var heavy = 0, square3 = 0, lines = 0
        var wiped = false, clearedAny = false
        let heavyLimit = Tuning.maxHeavy(d), square3Limit = Tuning.maxSquare3(d)

        for _ in 0..<3 {
            var allowed = [Double](repeating: 0, count: catalogCount)
            for p in 0..<catalogCount {
                var w = base[p]
                if familyCount[familyOfShape[p]] >= 2 { w = 0 }
                if cellsOfShape[p] >= Tuning.heavyCells && heavy >= heavyLimit { w = 0 }
                if isSquare3[p] && square3 >= square3Limit { w = 0 }
                allowed[p] = w
            }
            var options: [(shape: Int, board: UInt64, lines: Int)] = []
            var optionWeights: [Double] = []
            for p in 0..<catalogCount where allowed[p] > 0 {
                let masks = ShapeCatalog.placementSets[p].masks
                var k = 0
                while k < masks.count {
                    let m = masks[k]
                    k += 1
                    if board & m != 0 { continue }
                    let (next, cleared) = BoardBits.clearFullLines(board | m)
                    guard cleared > 0 else { continue }
                    options.append((p, next, cleared))
                    optionWeights.append(allowed[p] * Double(1 + cleared * cleared) * (next == 0 ? 40 : 1))
                }
            }
            let pick: Int
            if options.isEmpty {
                pick = weightedPick(allowed, &rng)
                guard allowed[pick] > 0 else { return nil }
            } else {
                let o = options[weightedPick(optionWeights, &rng)]
                pick = o.shape
                board = o.board
                lines += o.lines
                clearedAny = true
                if o.board == 0 { wiped = true }
            }
            tray.append(pick)
            familyCount[familyOfShape[pick]] += 1
            if cellsOfShape[pick] >= Tuning.heavyCells { heavy += 1 }
            if isSquare3[pick] { square3 += 1 }
        }
        guard clearedAny else { return nil }
        // The simulated board only counts clearing steps, so the hint is a lower bound on the real outcome.
        let score = wiped ? outcomeValue(wiped: true, lines: lines, board: 0) : lines * 100
        shuffle(&tray, &rng)
        return (tray, score)
    }

    #if DEBUG
    /// Replays the witness through the real `Board.place` (an independent code path from the bitboard search).
    private static func verify(_ deal: Deal, on board: Board) {
        guard deal.witness.count == 3 else {
            assertionFailure("witness must place all 3 pieces")
            return
        }
        var copy = board
        for step in deal.witness {
            let piece = deal.pieces[step.slot]
            guard copy.canPlace(piece.shape, at: step.origin) else {
                assertionFailure("witness step \(piece.shape.id) at \(step.origin) is not placeable")
                return
            }
            copy.place(piece.shape, color: piece.color, at: step.origin)
        }
    }
    #endif
}
