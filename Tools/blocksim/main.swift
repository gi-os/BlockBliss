// blocksim: Monte-Carlo simulator for the Block Bliss engine and piece generator.
//
//   swift run -c release blocksim --games 2000 --seed 1
//
// Plays full games through the real `GameEngine` with a few bots and reports solvability, fallback usage,
// generator timing, score and survival distributions, and which piece families get dealt at each
// difficulty band. Everything is deterministic for a given --seed (timings aside).

import BlockEngine
import Dispatch
import Foundation

// MARK: - Options

struct Options {
    var games = 2000
    var seed: UInt64 = 1
    var maxRounds = 1000
    var threads = ProcessInfo.processInfo.activeProcessorCount
    var bots: [BotKind] = [.greedy, .random]
    var randomGames: Int?          // defaults to min(games, 500)
    var stressBoards = 3000
    var solverCases = 30_000
}

enum BotKind: String { case greedy, random }

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        FileHandle.standardError.write(Data("usage: blocksim [--games N] [--seed S] [--max-rounds R] [--threads T] [--bots greedy,random] [--random-games N] [--stress-boards N] [--solver-cases N]\n".utf8))
        exit(2)
    }
    while !args.isEmpty {
        let flag = args.removeFirst()
        func value() -> String {
            guard !args.isEmpty else { fail("missing value for \(flag)") }
            return args.removeFirst()
        }
        switch flag {
        case "--games": guard let n = Int(value()), n > 0 else { fail("bad --games") }; o.games = n
        case "--seed": guard let n = UInt64(value()) else { fail("bad --seed") }; o.seed = n
        case "--max-rounds": guard let n = Int(value()), n > 0 else { fail("bad --max-rounds") }; o.maxRounds = n
        case "--threads": guard let n = Int(value()), n > 0 else { fail("bad --threads") }; o.threads = n
        case "--random-games": guard let n = Int(value()), n > 0 else { fail("bad --random-games") }; o.randomGames = n
        case "--stress-boards": guard let n = Int(value()), n >= 0 else { fail("bad --stress-boards") }; o.stressBoards = n
        case "--solver-cases": guard let n = Int(value()), n >= 0 else { fail("bad --solver-cases") }; o.solverCases = n
        case "--bots":
            let names = value().split(separator: ",").map(String.init)
            let kinds = names.compactMap(BotKind.init(rawValue:))
            guard kinds.count == names.count, !kinds.isEmpty else { fail("bad --bots (greedy, random)") }
            o.bots = kinds
        default: fail("unknown flag \(flag)")
        }
    }
    return o
}

// MARK: - Bitboard helpers (the engine's internals are not public, so the bots carry their own)

enum Bits {
    static let col0: UInt64 = 0x0101_0101_0101_0101
    static let col7: UInt64 = col0 << 7
    static let row0: UInt64 = 0xFF
    static let row7: UInt64 = row0 << 56

    /// Board after clearing full rows/columns, and how many lines cleared.
    @inline(__always)
    static func clear(_ b: UInt64) -> (UInt64, Int) {
        var x = b & (b >> 1); x &= x >> 2; x &= x >> 4
        let rows = x & col0
        var c = b & (b >> 8); c &= c >> 16; c &= c >> 32
        let cols = c & 0xFF
        let n = rows.nonzeroBitCount + cols.nonzeroBitCount
        if n == 0 { return (b, 0) }
        return (b & ~((rows &* 0xFF) | (cols &* col0)), n)
    }

    /// Board-quality heuristic: fewer filled/empty boundaries, fewer filled cells, no walled-in holes.
    static func evaluate(_ b: UInt64) -> Double {
        let edges = ((b ^ (b >> 1)) & 0x7F7F_7F7F_7F7F_7F7F).nonzeroBitCount
            + ((b ^ (b >> 8)) & 0x00FF_FFFF_FFFF_FFFF).nonzeroBitCount
        let leftFilled = (b << 1) | col0, rightFilled = (b >> 1) | col7
        let upFilled = (b << 8) | row0, downFilled = (b >> 8) | row7
        let holes = (~b & leftFilled & rightFilled & upFilled & downFilled).nonzeroBitCount
        return -Double(edges) - 0.7 * Double(b.nonzeroBitCount) - 3.0 * Double(holes)
    }
}

struct Placement { let mask: UInt64; let origin: Cell }

/// Every in-bounds placement per shape id.
let placementTable: [String: [Placement]] = {
    var table: [String: [Placement]] = [:]
    for shape in ShapeCatalog.all {
        var list: [Placement] = []
        for r in 0...(Board.size - shape.height) {
            for c in 0...(Board.size - shape.width) {
                list.append(Placement(mask: shape.maskAt(row: r, col: c), origin: Cell(r, c)))
            }
        }
        table[shape.id] = list
    }
    return table
}()

// MARK: - Bots

struct Move { let trayIndex: Int; let origin: Cell }

protocol Bot {
    mutating func nextMove(_ state: GameState) -> Move?
}

/// Picks a uniformly random legal (piece, origin) pair.
struct RandomBot: Bot {
    var rng: SeededRNG
    mutating func nextMove(_ state: GameState) -> Move? {
        var options: [Move] = []
        for (i, piece) in state.tray.enumerated() {
            guard let piece else { continue }
            for p in placementTable[piece.shape.id]! where state.board.occupancy & p.mask == 0 {
                options.append(Move(trayIndex: i, origin: p.origin))
            }
        }
        return options.isEmpty ? nil : options[Int(rng.next() % UInt64(options.count))]
    }
}

/// Looks at every order of the remaining pieces; within an order places each piece greedily for
/// (lines cleared, then board quality); plays the first step of the best plan, then re-plans.
struct GreedyBot: Bot {
    static let permutations: [[[Int]]] = [
        [[]],
        [[0]],
        [[0, 1], [1, 0]],
        [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]],
    ]

    mutating func nextMove(_ state: GameState) -> Move? {
        let remaining = state.tray.enumerated().compactMap { i, piece in piece.map { (index: i, shape: $0.shape) } }
        guard !remaining.isEmpty else { return nil }
        var best: (steps: Int, value: Double, first: Move)?
        for order in Self.permutations[remaining.count] {
            var board = state.board.occupancy
            var first: Move?
            var steps = 0
            var lines = 0
            for k in order {
                let piece = remaining[k]
                var pick: (value: Double, board: UInt64, lines: Int, origin: Cell)?
                for p in placementTable[piece.shape.id]! where board & p.mask == 0 {
                    let (next, n) = Bits.clear(board | p.mask)
                    let v = Bits.evaluate(next) + 8.0 * Double(n)
                    if pick == nil || v > pick!.value { pick = (v, next, n, p.origin) }
                }
                guard let pick else { break }
                if first == nil { first = Move(trayIndex: piece.index, origin: pick.origin) }
                board = pick.board
                lines += pick.lines
                steps += 1
            }
            guard let first else { continue }
            let value = Bits.evaluate(board) + 4.0 * Double(lines)
            if best == nil || steps > best!.steps || (steps == best!.steps && value > best!.value) {
                best = (steps, value, first)
            }
        }
        return best?.first
    }
}

// MARK: - Statistics

let familyCases = PieceFamily.allCases
let bandCount = 4

struct Stats {
    var games = 0
    var capped = 0
    var deals = 0
    var solvable = 0
    var engineMismatches = 0                     // engine's dealt tray != replayed generator call
    var invariantViolations = 0
    var levels = [Int](repeating: 0, count: 5)
    var genMicros: [Double] = []              // thread CPU time per deal
    var genWallMicros: [Double] = []
    var nodes: [Int] = []
    var finalScores: [Int] = []
    var rounds: [Int] = []
    var lines: [Int] = []
    var bestCombos: [Int] = []
    var allClears = 0
    var difficultyAtEnd: [Double] = []
    // per difficulty band: deals, family counts, total cells, heavy pieces, trays with a duplicate pose
    var bandDeals = [Int](repeating: 0, count: bandCount)
    var bandFamilies = [[Int]](repeating: [Int](repeating: 0, count: familyCases.count), count: bandCount)
    var bandCells = [Int](repeating: 0, count: bandCount)
    var bandHeavy = [Int](repeating: 0, count: bandCount)
    var bandDuplicates = [Int](repeating: 0, count: bandCount)
    // score reached when each checkpoint round is dealt (only games that got that far)
    static let checkpoints = [20, 40, 60, 100, 150, 250]
    var checkpointScores: [Int: [Int]] = [:]

    mutating func merge(_ o: Stats) {
        games += o.games; capped += o.capped; deals += o.deals; solvable += o.solvable
        engineMismatches += o.engineMismatches; invariantViolations += o.invariantViolations
        for i in levels.indices { levels[i] += o.levels[i] }
        genMicros += o.genMicros; genWallMicros += o.genWallMicros; nodes += o.nodes
        finalScores += o.finalScores; rounds += o.rounds; lines += o.lines; bestCombos += o.bestCombos
        allClears += o.allClears; difficultyAtEnd += o.difficultyAtEnd
        for b in 0..<bandCount {
            bandDeals[b] += o.bandDeals[b]; bandCells[b] += o.bandCells[b]
            bandHeavy[b] += o.bandHeavy[b]; bandDuplicates[b] += o.bandDuplicates[b]
            for f in familyCases.indices { bandFamilies[b][f] += o.bandFamilies[b][f] }
        }
        for (k, v) in o.checkpointScores { checkpointScores[k, default: []] += v }
    }
}

func nowMicros() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000 }
/// CPU time of the calling thread: unlike wall-clock it is not inflated when the OS preempts the process.
func cpuMicros() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000 }

/// Records one dealt tray: verifies it, replays the generator for exact fallback/timing data, bins it.
func recordDeal(stats: inout Stats, state: GameState, history: [[String]], preDealRNG: SeededRNG, preDealColorRNG: SeededRNG) {
    var rng = preDealRNG, colorRNG = preDealColorRNG
    let round = state.round - 1
    let startedWall = nowMicros(), startedCPU = cpuMicros()
    let deal = PieceGenerator.deal(board: state.board, score: state.score, round: round, history: history,
                                   rng: &rng, colorRNG: &colorRNG)
    stats.genMicros.append(cpuMicros() - startedCPU)
    stats.genWallMicros.append(nowMicros() - startedWall)
    stats.nodes.append(deal.nodesSearched)
    stats.deals += 1
    stats.levels[deal.fallbackLevel] += 1

    let dealtShapes = state.tray.compactMap { $0?.shape }
    if dealtShapes.map(\.id) != deal.pieces.map(\.shape.id) || rng != state.rng { stats.engineMismatches += 1 }
    if dealtShapes.count == 3, Solver.canPlaceAll(dealtShapes, on: state.board.occupancy) { stats.solvable += 1 }

    let d = PieceGenerator.difficulty(score: state.score, round: round)
    let band = min(bandCount - 1, Int(d * Double(bandCount)))
    stats.bandDeals[band] += 1
    for shape in dealtShapes {
        stats.bandFamilies[band][familyCases.firstIndex(of: shape.family)!] += 1
        stats.bandCells[band] += shape.cellCount
        if shape.cellCount >= 5 { stats.bandHeavy[band] += 1 }
    }
    if Set(dealtShapes.map(\.id)).count < dealtShapes.count { stats.bandDuplicates[band] += 1 }
}

func playGame(seed: UInt64, bot kind: BotKind, maxRounds: Int) -> Stats {
    var stats = Stats()
    var engine = GameEngine(seed: seed)
    var bot: Bot = kind == .greedy ? GreedyBot() : RandomBot(rng: SeededRNG(seed: seed ^ 0xB07B_07B0_7B07))
    stats.games = 1

    // The first deal comes from init(seed:): replay it from the untouched initial RNG streams.
    let initial = GameState(seed: seed)
    recordDeal(stats: &stats, state: engine.state, history: [], preDealRNG: initial.rng, preDealColorRNG: initial.colorRNG)

    while !engine.state.isGameOver {
        if engine.state.round > maxRounds { stats.capped = 1; break }
        guard let move = bot.nextMove(engine.state) else { break }
        let rngBefore = engine.state.rng, colorBefore = engine.state.colorRNG, historyBefore = engine.state.trayHistory
        guard let outcome = engine.place(trayIndex: move.trayIndex, at: move.origin) else {
            fatalError("bot proposed an illegal move \(move)")
        }
        if outcome.newTrayDealt {
            recordDeal(stats: &stats, state: engine.state, history: historyBefore, preDealRNG: rngBefore, preDealColorRNG: colorBefore)
            if let r = Stats.checkpoints.first(where: { $0 == engine.state.round - 1 }) {
                stats.checkpointScores[r, default: []].append(engine.state.score)
            }
        }
        // Lemma A: reachable boards never hold a full line and always keep at least 8 empty cells.
        let occupancy = engine.state.board.occupancy
        let full = BitBoard.fullLines(occupancy)
        if !(full.rows.isEmpty && full.cols.isEmpty) || occupancy.nonzeroBitCount > 56 { stats.invariantViolations += 1 }
    }
    let s = engine.state
    stats.finalScores.append(s.score)
    stats.rounds.append(stats.capped == 1 ? maxRounds : s.round)
    stats.lines.append(s.linesCleared)
    stats.bestCombos.append(s.bestComboThisGame)
    stats.allClears += s.allClears
    stats.difficultyAtEnd.append(PieceGenerator.difficulty(score: s.score, round: s.round - 1))
    return stats
}

// MARK: - Running

final class ResultBox: @unchecked Sendable {
    private var results: [Stats?]
    private let lock = NSLock()
    init(count: Int) { results = [Stats?](repeating: nil, count: count) }
    func store(_ stats: Stats, at i: Int) { lock.lock(); results[i] = stats; lock.unlock() }
    func merged() -> Stats {
        var total = Stats()
        for r in results { total.merge(r!) }      // merged in game order, so output is deterministic
        return total
    }
}

func run(bot: BotKind, games: Int, options: Options) -> Stats {
    let box = ResultBox(count: games)
    let seed = options.seed, maxRounds = options.maxRounds
    if options.threads == 1 {
        for i in 0..<games { box.store(playGame(seed: seed &+ UInt64(i), bot: bot, maxRounds: maxRounds), at: i) }
    } else {
        DispatchQueue.concurrentPerform(iterations: games) { i in
            box.store(playGame(seed: seed &+ UInt64(i), bot: bot, maxRounds: maxRounds), at: i)
        }
    }
    return box.merged()
}

// MARK: - Reporting

func percentile<T: Comparable>(_ sorted: [T], _ p: Double) -> T {
    sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

func fmt(_ v: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }

func report(_ title: String, _ s: Stats, maxRounds: Int) {
    print("\n==== \(title) ====")
    let scores = s.finalScores.sorted(), rounds = s.rounds.sorted()
    let avg = { (xs: [Int]) in Double(xs.reduce(0, +)) / Double(max(1, xs.count)) }
    print("games \(s.games)  deals \(s.deals)  capped at \(maxRounds) rounds: \(s.capped)")
    print("solvable deals: \(s.solvable)/\(s.deals) = \(fmt(100 * Double(s.solvable) / Double(max(1, s.deals)), 3))%   engine/replay mismatches: \(s.engineMismatches)   board-invariant violations: \(s.invariantViolations)")
    let L = s.levels
    let pct = { (n: Int) in fmt(100 * Double(n) / Double(max(1, s.deals)), 3) }
    print("fallback ladder: L0 normal \(L[0]) (\(pct(L[0]))%)  L1 friendly \(L[1]) (\(pct(L[1]))%)  L2 easy-pool \(L[2]) (\(pct(L[2]))%)  L3 fixed \(L[3]) (\(pct(L[3]))%)  L4 singles \(L[4]) (\(pct(L[4]))%)")
    let micros = s.genMicros.sorted(), wall = s.genWallMicros.sorted()
    let nodes = s.nodes.sorted()
    func ms(_ v: [Double], _ p: Double) -> String { fmt(percentile(v, p) / 1000, 3) }
    print("generator CPU time (ms/deal): p50 \(ms(micros, 0.5))  p99 \(ms(micros, 0.99))  p99.9 \(ms(micros, 0.999))  max \(fmt(micros.last! / 1000, 3))  mean \(fmt(micros.reduce(0, +) / Double(micros.count) / 1000, 3))")
    print("generator wall time (ms/deal): p50 \(ms(wall, 0.5))  p99 \(ms(wall, 0.99))  p99.9 \(ms(wall, 0.999))  max \(fmt(wall.last! / 1000, 3))   (wall includes OS preemption; use --threads 1 on a quiet machine)")
    print("search nodes/deal: p50 \(percentile(nodes, 0.5))  p99 \(percentile(nodes, 0.99))  max \(nodes.last!)")
    print("final score: mean \(fmt(avg(s.finalScores), 0))  median \(percentile(scores, 0.5))  p10 \(percentile(scores, 0.1))  p90 \(percentile(scores, 0.9))  max \(scores.last!)")
    print("rounds (trays dealt): mean \(fmt(avg(s.rounds)))  median \(percentile(rounds, 0.5))  p10 \(percentile(rounds, 0.1))  p25 \(percentile(rounds, 0.25))  p75 \(percentile(rounds, 0.75))  p90 \(percentile(rounds, 0.9))  min \(rounds.first!)  max \(rounds.last!)")
    print("avg lines cleared \(fmt(avg(s.lines)))  avg best combo \(fmt(avg(s.bestCombos)))  all-clears/game \(fmt(Double(s.allClears) / Double(s.games), 2))  mean difficulty at end \(fmt(s.difficultyAtEnd.reduce(0, +) / Double(s.games), 2))")

    // Survival histogram
    let edges = [5, 10, 20, 40, 60, 100, 150, 250, 500, 1000, Int.max]
    var hist = "survival: "
    var lower = 0
    for e in edges {
        let n = rounds.filter { $0 >= lower && $0 < e }.count
        if n > 0 { hist += "[\(lower)-\(e == Int.max ? "inf" : String(e - 1))]=\(fmt(100 * Double(n) / Double(rounds.count)))%  " }
        lower = e
    }
    print(hist)

    // Score-per-round checkpoints (used to calibrate PieceGenerator.Tuning.scorePerRound)
    var cps: [String] = []
    for r in Stats.checkpoints {
        guard let list = s.checkpointScores[r], list.count >= 5 else { continue }
        let sorted = list.sorted()
        let median = percentile(sorted, 0.5)
        cps.append("r\(r): median score \(median) (\(fmt(Double(median) / Double(r))) /round, n=\(list.count))")
    }
    if !cps.isEmpty { print("score at round: " + cps.joined(separator: "  |  ")) }

    // Family frequency per difficulty band
    print("piece-family share (% of dealt pieces) by difficulty band:")
    let bandNames = ["d<0.25", "0.25-0.5", "0.5-0.75", "d>=0.75"]
    var header = "  family       "
    for b in 0..<bandCount { header += bandNames[b].padding(toLength: 10, withPad: " ", startingAt: 0) }
    print(header)
    for (f, family) in familyCases.enumerated() {
        var row = "  " + family.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
        for b in 0..<bandCount {
            let pieces = max(1, s.bandDeals[b] * 3)
            row += (s.bandDeals[b] == 0 ? "-" : fmt(100 * Double(s.bandFamilies[b][f]) / Double(pieces))).padding(toLength: 10, withPad: " ", startingAt: 0)
        }
        print(row)
    }
    var summary = "  deals        "
    for b in 0..<bandCount { summary += String(s.bandDeals[b]).padding(toLength: 10, withPad: " ", startingAt: 0) }
    print(summary)
    var cells = "  cells/piece  "
    for b in 0..<bandCount { cells += (s.bandDeals[b] == 0 ? "-" : fmt(Double(s.bandCells[b]) / Double(s.bandDeals[b] * 3), 2)).padding(toLength: 10, withPad: " ", startingAt: 0) }
    print(cells)
    var heavy = "  heavy %      "
    for b in 0..<bandCount { heavy += (s.bandDeals[b] == 0 ? "-" : fmt(100 * Double(s.bandHeavy[b]) / Double(s.bandDeals[b] * 3))).padding(toLength: 10, withPad: " ", startingAt: 0) }
    print(heavy)
    var dup = "  dup-pose %   "
    for b in 0..<bandCount { dup += (s.bandDeals[b] == 0 ? "-" : fmt(100 * Double(s.bandDuplicates[b]) / Double(s.bandDeals[b]), 2)).padding(toLength: 10, withPad: " ", startingAt: 0) }
    print(dup)
}

// MARK: - Stress: the generator on arbitrary reachable-looking boards

/// Random board with exactly `fill` cells (8...56) and no full line: sparse boards by rejection, dense ones
/// from a one-empty-per-row-and-column skeleton.
func randomStableBoard(fill: Int, rng: inout SeededRNG) -> UInt64 {
    func stable(_ b: UInt64) -> Bool { let f = BitBoard.fullLines(b); return f.rows.isEmpty && f.cols.isEmpty }
    if fill <= 36 {
        while true {
            var b: UInt64 = 0
            while b.nonzeroBitCount < fill { b |= 1 << (rng.next() % 64) }
            if stable(b) { return b }
        }
    }
    var perm = Array(0..<8)
    for i in stride(from: 7, to: 0, by: -1) { perm.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
    var b = UInt64.max
    for (r, c) in perm.enumerated() { b &= ~(1 << UInt64(r * 8 + c)) }
    while b.nonzeroBitCount > fill { b &= ~(1 << (rng.next() % 64)) }
    return b
}

func occupancyBoard(_ occupancy: UInt64) -> Board {
    Board(rows: (0..<8).map { r in String((0..<8).map { c in occupancy & (1 << UInt64(r * 8 + c)) != 0 ? Character("X") : Character(".") }) })
}

func runStress(boards: Int, seed: UInt64) -> Bool {
    guard boards > 0 else { return true }
    var rng = SeededRNG(seed: seed ^ 0x57_2E55)
    var cpu: [Double] = []
    var levels = [Int](repeating: 0, count: 5)
    var worstFill = 0, bad = 0
    var perFill = [Int: [Double]]()
    for i in 0..<boards {
        // every third board is the adversarial case: 8 empty cells, one per row and column, none touching
        var occupancy: UInt64
        let fill: Int
        if i % 3 == 2 {
            while true {
                var perm = Array(0..<8)
                for k in stride(from: 7, to: 0, by: -1) { perm.swapAt(k, Int(rng.next() % UInt64(k + 1))) }
                if (0..<7).allSatisfy({ abs(perm[$0] - perm[$0 + 1]) >= 2 }) {
                    occupancy = ~perm.enumerated().reduce(UInt64(0)) { $0 | (1 << UInt64($1.offset * 8 + $1.element)) }
                    break
                }
            }
            fill = 56
        } else {
            fill = 8 + Int(rng.next() % 49)
            occupancy = randomStableBoard(fill: fill, rng: &rng)
        }
        let board = occupancyBoard(occupancy)
        var shapeRNG = SeededRNG(seed: seed &+ UInt64(i)), colorRNG = SeededRNG(seed: ~seed &+ UInt64(i))
        let score = Int(rng.next() % 40_000), round = Int(rng.next() % 250)
        let t0 = cpuMicros()
        let deal = PieceGenerator.deal(board: board, score: score, round: round, history: [], rng: &shapeRNG, colorRNG: &colorRNG)
        let t = cpuMicros() - t0
        cpu.append(t)
        perFill[fill / 8 * 8, default: []].append(t)
        levels[deal.fallbackLevel] += 1
        if t >= (cpu.max() ?? 0) { worstFill = fill }
        if !Solver.canPlaceAll(deal.pieces.map(\.shape), on: occupancy) { bad += 1 }
    }
    let sorted = cpu.sorted()
    print("\n==== generator stress: \(boards) random stable boards (fill 8-56, every 3rd = adversarial 8-empty permutation board) ====")
    print("unsolvable deals: \(bad)   levels L0..L4: \(levels)")
    print("CPU ms/deal: p50 \(fmt(percentile(sorted, 0.5) / 1000, 3))  p99 \(fmt(percentile(sorted, 0.99) / 1000, 3))  p99.9 \(fmt(percentile(sorted, 0.999) / 1000, 3))  max \(fmt(sorted.last! / 1000, 3)) (fill \(worstFill))")
    print("mean CPU ms by fill bucket: " + perFill.keys.sorted().map { k in "\(k)+: \(fmt(perFill[k]!.reduce(0, +) / Double(perFill[k]!.count) / 1000, 3))" }.joined(separator: "  "))
    return bad == 0
}

// MARK: - Solver micro-benchmark

func runSolverBench(cases: Int, seed: UInt64) {
    guard cases > 0 else { return }
    var rng = SeededRNG(seed: seed ^ 0x5017E4)
    var solvable: [Double] = [], unsolvable: [Double] = []
    var worst: (micros: Double, desc: String) = (0, "")
    for _ in 0..<cases {
        let fill = 8 + Int(rng.next() % 54)
        var occupancy: UInt64 = 0
        while occupancy.nonzeroBitCount < fill { occupancy |= 1 << (rng.next() % 64) }
        let shapes = (0..<3).map { _ in ShapeCatalog.all[Int(rng.next() % UInt64(ShapeCatalog.all.count))] }
        let t0 = cpuMicros()
        let ok = Solver.canPlaceAll(shapes, on: occupancy)
        let t = cpuMicros() - t0
        if ok { solvable.append(t) } else { unsolvable.append(t) }
        if t > worst.micros { worst = (t, "fill \(fill) \(shapes.map(\.id)) -> \(ok)") }
    }
    // empty / nearly empty boards with the heaviest trays
    var emptyWorst = 0.0
    let heavy = ShapeCatalog.all.filter { $0.cellCount >= 5 }
    for a in heavy { for b in heavy { for c in heavy {
        let t0 = cpuMicros()
        _ = Solver.canPlaceAll([a, b, c], on: 0)
        emptyWorst = max(emptyWorst, cpuMicros() - t0)
    } } }
    func line(_ name: String, _ v: [Double]) {
        guard !v.isEmpty else { return }
        let s = v.sorted()
        print("  \(name): n=\(s.count)  p50 \(fmt(percentile(s, 0.5), 1)) us  p99 \(fmt(percentile(s, 0.99), 1)) us  max \(fmt(s.last!, 1)) us")
    }
    print("\n==== Solver.canPlaceAll benchmark (CPU time, 3 random pieces on random boards) ====")
    line("solvable  ", solvable)
    line("unsolvable", unsolvable)
    print("  worst case seen: \(fmt(worst.micros / 1000, 3)) ms  (\(worst.desc))")
    print("  all \(heavy.count * heavy.count * heavy.count) heavy-piece trays on an empty board: worst \(fmt(emptyWorst, 1)) us")
}

// MARK: - Main

let options = parseOptions()
print("blocksim: games \(options.games), seed \(options.seed), max rounds \(options.maxRounds), threads \(options.threads), generator v\(PieceGenerator.version)")
let wallStart = Date()
var unsolvable = 0
for kind in options.bots {
    let games = kind == .random ? (options.randomGames ?? min(options.games, 500)) : options.games
    let started = Date()
    let stats = run(bot: kind, games: games, options: options)
    let title = kind == .greedy ? "greedy bot (plans every order of the tray, maximises lines then board shape)" : "random-ish bot (uniformly random legal move)"
    report(title, stats, maxRounds: options.maxRounds)
    print("(\(fmt(Date().timeIntervalSince(started))) s)")
    unsolvable += stats.deals - stats.solvable + stats.engineMismatches + stats.invariantViolations
}
var ok = runStress(boards: options.stressBoards, seed: options.seed)
runSolverBench(cases: options.solverCases, seed: options.seed)
print("\ntotal wall time \(fmt(Date().timeIntervalSince(wallStart))) s")
if unsolvable > 0 || !ok {
    print("FAILED: \(unsolvable) unsolvable deals / mismatches / invariant violations, stress ok: \(ok)")
    exit(1)
}
