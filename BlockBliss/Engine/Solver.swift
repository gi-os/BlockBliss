import Foundation

// MARK: - Public API

/// Exact solvability search: can a set of pieces all be placed, in some order, with every full row and
/// column cleared after each placement? Clears matter because they can free room for later pieces.
public enum Solver {
    /// True if all shapes can be placed on `occupancy` in SOME order (with line clears applied between placements).
    public static func canPlaceAll(_ shapes: [Shape], on occupancy: UInt64) -> Bool {
        var search = TraySearch(shapes.map(ShapeCatalog.placements(for:)), nodeCap: .max)
        return search.run(on: occupancy)
    }

    /// One concrete solution (order + origins), or nil. `shapeIndex` indexes into `shapes`.
    public static func solve(_ shapes: [Shape], on occupancy: UInt64) -> [(shapeIndex: Int, origin: Cell)]? {
        var search = TraySearch(shapes.map(ShapeCatalog.placements(for:)), nodeCap: .max)
        guard search.run(on: occupancy) else { return nil }
        return search.witness.map { (shapeIndex: $0.slot, origin: $0.origin) }
    }
}

// MARK: - Bit tricks

enum BoardBits {
    private static let columnBits: UInt64 = 0x0101_0101_0101_0101

    /// Occupancy after clearing every full row and column at once, plus how many lines were cleared.
    /// Branch-free detection: a log-step AND folds each row (or column) down to a single bit.
    @inline(__always)
    static func clearFullLines(_ b: UInt64) -> (board: UInt64, lines: Int) {
        var x = b & (b >> 1); x &= x >> 2; x &= x >> 4
        let rows = x & columnBits                     // bit 8r set  <=>  row r full
        var c = b & (b >> 8); c &= c >> 16; c &= c >> 32
        let cols = c & 0xFF                           // bit c set   <=>  column c full
        let lines = rows.nonzeroBitCount + cols.nonzeroBitCount
        if lines == 0 { return (b, 0) }
        return (b & ~((rows &* 0xFF) | (cols &* columnBits)), lines)
    }
}

// MARK: - Failure memo

/// Open-addressing set of (occupancy, remaining-slots) states already proven unsolvable.
/// A generation counter makes `reset()` O(1), and the table doubles at 50% load.
struct FailureMemo {
    private var boards: [UInt64]
    private var remaining: [UInt16]
    private var generations: [UInt32]
    private var generation: UInt32 = 1
    private var count = 0
    private var slotMask: Int

    init(capacityPower: Int = 11) {
        let size = 1 << capacityPower
        boards = [UInt64](repeating: 0, count: size)
        remaining = [UInt16](repeating: 0, count: size)
        generations = [UInt32](repeating: 0, count: size)
        slotMask = size - 1
    }

    mutating func reset() {
        count = 0
        generation &+= 1
        if generation == 0 {            // wrapped: stale tags could alias, so wipe once
            for i in generations.indices { generations[i] = 0 }
            generation = 1
        }
    }

    @inline(__always)
    private func slot(_ board: UInt64, _ rem: UInt16) -> Int {
        var h = (board ^ (UInt64(rem) &* 0x9E37_79B9_7F4A_7C15)) &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 32
        return Int(truncatingIfNeeded: h) & slotMask
    }

    func contains(_ board: UInt64, _ rem: UInt16) -> Bool {
        var i = slot(board, rem)
        while generations[i] == generation {
            if boards[i] == board && remaining[i] == rem { return true }
            i = (i + 1) & slotMask
        }
        return false
    }

    mutating func insert(_ board: UInt64, _ rem: UInt16) {
        if (count + 1) * 2 > slotMask + 1 { grow() }
        var i = slot(board, rem)
        while generations[i] == generation {
            if boards[i] == board && remaining[i] == rem { return }
            i = (i + 1) & slotMask
        }
        boards[i] = board; remaining[i] = rem; generations[i] = generation
        count += 1
    }

    private mutating func grow() {
        let oldBoards = boards, oldRemaining = remaining, oldGenerations = generations
        let size = (slotMask + 1) * 2
        boards = [UInt64](repeating: 0, count: size)
        remaining = [UInt16](repeating: 0, count: size)
        generations = [UInt32](repeating: 0, count: size)
        slotMask = size - 1
        let live = generation
        count = 0
        for j in oldBoards.indices where oldGenerations[j] == live {
            var i = slot(oldBoards[j], oldRemaining[j])
            while generations[i] == live { i = (i + 1) & slotMask }
            boards[i] = oldBoards[j]; remaining[i] = oldRemaining[j]; generations[i] = live
            count += 1
        }
    }
}

// MARK: - DFS over orderings x placements

/// Depth-first search over (ordering of the pieces) x (placement of each), applying line clears between
/// placements. Reusable: `load` re-targets it at a new tray without reallocating the memo.
///
/// Pruning:
///  1. the last piece only needs *some* placement to fit (no recursion);
///  2. a failure memo keyed on (occupancy, remaining slots) merges the different orderings and the
///     different placements that reach the same cleared board;
///  3. identical shapes are interchangeable, so only the lowest-numbered one of a group is tried per node;
///  4. early exit on the first complete solution.
///
/// `nodeCap` bounds the work by node count (never time, so results reproduce exactly). When the cap is hit
/// `aborted` is set and `run` returns false meaning "not proven", which callers must treat as unsolved.
struct TraySearch {
    private var sets: [PlacementSet] = []
    /// For slot i, the earlier slots holding an identical shape.
    private var duplicates: [UInt16] = []
    private var memo = FailureMemo()
    private var path: [(slot: Int, placement: Int)] = []

    private(set) var nodes = 0
    private(set) var aborted = false
    private var nodeCap = Int.max

    init() {}

    init(_ sets: [PlacementSet], nodeCap: Int) {
        load(sets, nodeCap: nodeCap)
    }

    mutating func load(_ newSets: [PlacementSet], nodeCap: Int) {
        precondition(newSets.count <= 16, "TraySearch supports at most 16 pieces")
        sets = newSets
        duplicates = newSets.indices.map { i in
            var mask: UInt16 = 0
            for j in 0..<i where newSets[j].shape.mask == newSets[i].shape.mask { mask |= 1 << UInt16(j) }
            return mask
        }
        self.nodeCap = nodeCap
        nodes = 0
        aborted = false
        path.removeAll(keepingCapacity: true)
        memo.reset()
    }

    /// Searches for a full solution from `occupancy`. On success `witness` holds it.
    mutating func run(on occupancy: UInt64) -> Bool {
        nodes = 0
        aborted = false
        path.removeAll(keepingCapacity: true)
        let all: UInt16 = sets.isEmpty ? 0 : UInt16(truncatingIfNeeded: (1 << sets.count) - 1)
        return search(occupancy, all)
    }

    /// The solution found by the last successful `run`: slot order of play with origins.
    var witness: [(slot: Int, origin: Cell)] {
        path.map { (slot: $0.slot, origin: sets[$0.slot].origin(ofPlacement: $0.placement)) }
    }

    private mutating func search(_ board: UInt64, _ rem: UInt16) -> Bool {
        if rem == 0 { return true }
        nodes += 1
        if nodes > nodeCap { aborted = true; return false }

        let isLast = rem & (rem &- 1) == 0
        if !isLast, memo.contains(board, rem) { return false }

        var bits = rem
        while bits != 0 {
            let slot = bits.trailingZeroBitCount
            bits &= bits &- 1
            if rem & duplicates[slot] != 0 { continue }       // an identical piece goes first
            let masks = sets[slot].masks
            let rest = rem & ~(1 << UInt16(slot))
            var k = 0
            while k < masks.count {
                let m = masks[k]
                if board & m == 0 {
                    path.append((slot, k))
                    if isLast { return true }
                    if search(BoardBits.clearFullLines(board | m).board, rest) { return true }
                    path.removeLast()
                    if aborted { return false }
                }
                k += 1
            }
        }
        if !isLast { memo.insert(board, rem) }
        return false
    }
}
