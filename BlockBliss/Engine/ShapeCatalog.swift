import Foundation

/// The 41 fixed orientations used by Block Blast (pieces never rotate, so every orientation is its own
/// `Shape`), in 15 families. Ids are the pose names from GENERATOR.md ("single", "domino_h", ... "diag3_anti").
///
/// Catalog order is part of the generator's determinism contract (weights and sampling are indexed by it),
/// so never reorder existing entries.
public enum ShapeCatalog {
    /// All 41 orientations in catalog order.
    public static let all: [Shape] = table.map { Shape(id: $0.id, family: $0.family, pattern: $0.pattern) }

    public static func shape(id: String) -> Shape? {
        indexByID[id].map { all[$0] }
    }

    public static func shapes(in family: PieceFamily) -> [Shape] {
        all.filter { $0.family == family }
    }

    // MARK: Table

    private static let table: [(id: String, family: PieceFamily, pattern: String)] = [
        ("single", .single, "X"),
        ("domino_h", .line2, "XX"), ("domino_v", .line2, "X/X"),
        ("tri_h", .line3, "XXX"), ("tri_v", .line3, "X/X/X"),
        ("quad_h", .line4, "XXXX"), ("quad_v", .line4, "X/X/X/X"),
        ("penta_h", .line5, "XXXXX"), ("penta_v", .line5, "X/X/X/X/X"),
        ("sq2", .square2, "XX/XX"),
        ("sq3", .square3, "XXX/XXX/XXX"),
        ("rect_2x3", .rect2x3, "XXX/XXX"), ("rect_3x2", .rect2x3, "XX/XX/XX"),
        ("corner_nw", .corner3, "XX/X."), ("corner_ne", .corner3, "XX/.X"),
        ("corner_sw", .corner3, "X./XX"), ("corner_se", .corner3, ".X/XX"),
        ("l4_a", .lShape4, "X../XXX"), ("l4_b", .lShape4, "..X/XXX"),
        ("l4_c", .lShape4, "XXX/X.."), ("l4_d", .lShape4, "XXX/..X"),
        ("l4_e", .lShape4, "X./X./XX"), ("l4_f", .lShape4, ".X/.X/XX"),
        ("l4_g", .lShape4, "XX/X./X."), ("l4_h", .lShape4, "XX/.X/.X"),
        ("bigL_nw", .corner5, "XXX/X../X.."), ("bigL_ne", .corner5, "XXX/..X/..X"),
        ("bigL_sw", .corner5, "X../X../XXX"), ("bigL_se", .corner5, "..X/..X/XXX"),
        ("t_up", .tShape, "XXX/.X."), ("t_down", .tShape, ".X./XXX"),
        ("t_right", .tShape, "X./XX/X."), ("t_left", .tShape, ".X/XX/.X"),
        ("s_h", .sShape, ".XX/XX."), ("z_h", .sShape, "XX./.XX"),
        ("z_v", .sShape, "X./XX/.X"), ("s_v", .sShape, ".X/XX/X."),
        ("diag2_main", .diagonal2, "X./.X"), ("diag2_anti", .diagonal2, ".X/X."),
        ("diag3_main", .diagonal3, "X../.X./..X"), ("diag3_anti", .diagonal3, "..X/.X./X.."),
    ]

    // MARK: Internal lookup (generator / solver)

    private static let indexByID: [String: Int] = {
        var map: [String: Int] = [:]
        for (i, shape) in all.enumerated() { map[shape.id] = i }
        return map
    }()

    /// Catalog index of a shape id (dictionary used for lookup only; never iterated).
    static func index(ofID id: String) -> Int? { indexByID[id] }

    /// Precomputed placements for every catalog shape, parallel to `all`.
    static let placementSets: [PlacementSet] = all.map(PlacementSet.init)

    /// Placements for any shape. Catalog shapes hit the precomputed table; unknown shapes are computed.
    static func placements(for shape: Shape) -> PlacementSet {
        if let i = indexByID[shape.id], all[i].mask == shape.mask { return placementSets[i] }
        return PlacementSet(shape)
    }
}

/// Every in-bounds placement of one shape as a bitboard mask, row-major by origin.
struct PlacementSet {
    let shape: Shape
    let masks: [UInt64]
    /// Number of origin columns, `9 - width`, used to turn a placement index back into an origin.
    let originColumns: Int

    init(_ shape: Shape) {
        self.shape = shape
        originColumns = Board.size + 1 - shape.width
        var masks: [UInt64] = []
        if shape.width <= Board.size, shape.height <= Board.size {
            masks.reserveCapacity((Board.size + 1 - shape.height) * originColumns)
            for r in 0...(Board.size - shape.height) {
                for c in 0...(Board.size - shape.width) {
                    masks.append(shape.maskAt(row: r, col: c))
                }
            }
        }
        self.masks = masks
    }

    func origin(ofPlacement index: Int) -> Cell {
        Cell(row: index / originColumns, col: index % originColumns)
    }
}
