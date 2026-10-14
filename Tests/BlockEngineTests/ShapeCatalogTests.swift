import XCTest
@testable import BlockEngine

final class ShapeCatalogTests: XCTestCase {
    func testHasExactly41OrientationsWithUniqueIdsAndMasks() {
        let all = ShapeCatalog.all
        XCTAssertEqual(all.count, 41)
        XCTAssertEqual(Set(all.map(\.id)).count, 41, "ids must be unique")
        XCTAssertEqual(Set(all.map(\.mask)).count, 41, "no two orientations may be the same cells")
    }

    func testShapesAreNormalisedAndConsistent() {
        for s in ShapeCatalog.all {
            XCTAssertEqual(s.cells.map(\.row).min(), 0, s.id)
            XCTAssertEqual(s.cells.map(\.col).min(), 0, s.id)
            XCTAssertEqual(Set(s.cells).count, s.cells.count, "\(s.id) has duplicate cells")
            XCTAssertEqual(s.mask.nonzeroBitCount, s.cellCount, s.id)
            XCTAssertEqual(s.width, s.cells.map(\.col).max()! + 1, s.id)
            XCTAssertEqual(s.height, s.cells.map(\.row).max()! + 1, s.id)
            let rebuilt = s.cells.reduce(UInt64(0)) { $0 | (1 << UInt64($1.bit)) }
            XCTAssertEqual(rebuilt, s.mask, s.id)
            XCTAssertTrue(s.fitsInBounds(row: 0, col: 0), s.id)
        }
    }

    func testFamilySizes() {
        let expected: [PieceFamily: Int] = [
            .single: 1, .line2: 2, .line3: 2, .line4: 2, .line5: 2, .square2: 1, .square3: 1, .rect2x3: 2,
            .corner3: 4, .lShape4: 8, .corner5: 4, .tShape: 4, .sShape: 4, .diagonal2: 2, .diagonal3: 2,
        ]
        XCTAssertEqual(expected.count, PieceFamily.allCases.count)
        XCTAssertEqual(expected.values.reduce(0, +), 41)
        for family in PieceFamily.allCases {
            XCTAssertEqual(ShapeCatalog.shapes(in: family).count, expected[family], "\(family)")
        }
    }

    func testFamilyCellCounts() {
        let cells: [PieceFamily: Int] = [
            .single: 1, .line2: 2, .line3: 3, .line4: 4, .line5: 5, .square2: 4, .square3: 9, .rect2x3: 6,
            .corner3: 3, .lShape4: 4, .corner5: 5, .tShape: 4, .sShape: 4, .diagonal2: 2, .diagonal3: 3,
        ]
        for s in ShapeCatalog.all { XCTAssertEqual(s.cellCount, cells[s.family], s.id) }
    }

    /// Pieces never rotate in play, but each family must contain every rotation of each of its members.
    func testFamiliesAreClosedUnderRotation() {
        for family in PieceFamily.allCases {
            let members = ShapeCatalog.shapes(in: family)
            let masks = Set(members.map(\.mask))
            for member in members {
                // (r, c) -> (c, -r), then renormalise
                let rotated = member.cells.map { Cell(row: $0.col, col: -$0.row) }
                let candidate = Shape(id: "probe", family: family, cells: rotated)
                XCTAssertTrue(masks.contains(candidate.mask), "\(member.id) rotated is missing from \(family)")
            }
        }
    }

    func testLookupByIdAndFamilyOrder() {
        for s in ShapeCatalog.all { XCTAssertEqual(ShapeCatalog.shape(id: s.id), s) }
        XCTAssertNil(ShapeCatalog.shape(id: "nope"))
        XCTAssertEqual(ShapeCatalog.shapes(in: .lShape4).map(\.id), (["a", "b", "c", "d", "e", "f", "g", "h"]).map { "l4_\($0)" })
        XCTAssertEqual(ShapeCatalog.shape(id: "single")?.family, .single)
        XCTAssertEqual(ShapeCatalog.shape(id: "diag3_anti")?.family, .diagonal3)
    }

    func testSpecificOrientations() {
        XCTAssertEqual(shape("l4_a").cells, [Cell(0, 0), Cell(1, 0), Cell(1, 1), Cell(1, 2)])
        XCTAssertEqual(shape("t_up").cells, [Cell(0, 0), Cell(0, 1), Cell(0, 2), Cell(1, 1)])
        XCTAssertEqual(shape("diag3_anti").cells, [Cell(0, 2), Cell(1, 1), Cell(2, 0)])
        XCTAssertEqual(shape("corner_se").cells, [Cell(0, 1), Cell(1, 0), Cell(1, 1)])
        XCTAssertEqual(shape("s_h").cells, [Cell(0, 1), Cell(0, 2), Cell(1, 0), Cell(1, 1)])
        XCTAssertEqual(shape("sq3").cellCount, 9)
        XCTAssertEqual(shape("penta_v").height, 5)
        XCTAssertEqual(shape("rect_2x3").width, 3)
        XCTAssertEqual(shape("rect_3x2").height, 3)
    }

    func testPlacementTables() {
        var total = 0
        for (i, s) in ShapeCatalog.all.enumerated() {
            let set = ShapeCatalog.placementSets[i]
            XCTAssertEqual(set.masks.count, (9 - s.height) * (9 - s.width), s.id)
            XCTAssertEqual(Set(set.masks).count, set.masks.count, "\(s.id) placements must be distinct")
            for (k, mask) in set.masks.enumerated() {
                XCTAssertEqual(mask.nonzeroBitCount, s.cellCount, "\(s.id) placement \(k) is clipped")
                let origin = set.origin(ofPlacement: k)
                XCTAssertEqual(mask, s.maskAt(row: origin.row, col: origin.col), "\(s.id) placement \(k)")
            }
            total += set.masks.count
        }
        XCTAssertEqual(total, 1767)
    }

    func testPlacementsForUnknownShapeAreComputed() {
        let custom = Shape(id: "custom", family: .corner3, pattern: "X./XX")
        let set = ShapeCatalog.placements(for: custom)
        XCTAssertEqual(set.masks.count, 49)
        XCTAssertEqual(set.shape.id, "custom")
    }
}
