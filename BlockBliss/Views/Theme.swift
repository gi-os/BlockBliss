import SwiftUI

// MARK: - Colour helpers

extension Color {
    /// sRGB colour from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// Linear blend of two 0xRRGGBB colours in sRGB space (`t` = 0 gives `a`, 1 gives `b`).
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func channel(_ shift: UInt32) -> Double {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return (x + (y - x) * t) / 255
        }
        return Color(.sRGB, red: channel(16), green: channel(8), blue: channel(0), opacity: 1)
    }
}

// MARK: - Block palette (SPEC "Look": pixel-sampled bevel colours)

/// Every colour needed to draw one bevelled tile.
struct BlockPalette {
    let face: Color
    let faceTop: Color        // face gradient, top edge
    let faceBottom: Color     // face gradient, bottom edge
    let top: Color
    let left: Color
    let right: Color
    let bottom: Color
    let outline: Color        // thin dark outline around the whole tile

    init(face: UInt32, top: UInt32, left: UInt32, right: UInt32, bottom: UInt32) {
        self.face = Color(hex: face)
        faceTop = Color.mix(face, 0xFFFFFF, 0.07)
        faceBottom = Color.mix(face, 0x000000, 0.10)
        self.top = Color(hex: top)
        self.left = Color(hex: left)
        self.right = Color(hex: right)
        self.bottom = Color(hex: bottom)
        outline = Color.mix(bottom, 0x000000, 0.45)
    }
}

extension BlockColor {
    /// Indexed by `BlockColor.rawValue` (red, orange, yellow, green, cyan, blue, purple).
    private static let palettes: [BlockPalette] = [
        BlockPalette(face: 0xE04844, top: 0xFF9D97, left: 0xEA5A55, right: 0xAD302C, bottom: 0x8F2326),
        BlockPalette(face: 0xF35D18, top: 0xFEBC96, left: 0xF96A38, right: 0xD64A07, bottom: 0xAD3300),
        BlockPalette(face: 0xF5BF06, top: 0xFCF17C, left: 0xFACC26, right: 0xDB9C00, bottom: 0xBD7400),
        BlockPalette(face: 0x22C72E, top: 0x7FF6A0, left: 0x2AD93A, right: 0x109A29, bottom: 0x007A25),
        BlockPalette(face: 0x1AC4F0, top: 0x95F3FF, left: 0x3FD0F5, right: 0x009FDE, bottom: 0x0074B4),
        BlockPalette(face: 0x3660EF, top: 0x8ABFFF, left: 0x416DFA, right: 0x2450D7, bottom: 0x1E389E),
        BlockPalette(face: 0x9252E3, top: 0xE298F7, left: 0xB765F0, right: 0x7936AF, bottom: 0x5F228F),
    ]

    var palette: BlockPalette { Self.palettes[rawValue] }

    var spokenName: String {
        switch self {
        case .red: return "red"
        case .orange: return "orange"
        case .yellow: return "yellow"
        case .green: return "green"
        case .cyan: return "cyan"
        case .blue: return "blue"
        case .purple: return "purple"
        }
    }
}

// MARK: - Theme

enum Theme {
    static let backgroundGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: 0x4055B5), location: 0),
            .init(color: Color(hex: 0x4B67BF), location: 0.64),
            .init(color: Color(hex: 0x506FC5), location: 1),
        ],
        startPoint: .top, endPoint: .bottom)

    static let boardFrame = Color(hex: 0x30447A)
    static let emptyCell = Color(hex: 0x242C54)
    static let boardGap = Color(hex: 0x1E264A)

    static let crown = Color(hex: 0xF8C010)
    static let bestScore = Color(hex: 0xF8E000)
    static let gear = Color(hex: 0xB8E0F0)
    static let navy = Color(hex: 0x141B3D)

    /// Chunky rounded heavy font used for all game text.
    static func rounded(_ size: CGFloat, weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static let rainbow = LinearGradient(
        colors: [0xFF5A5F, 0xFF9A3D, 0xFFE03D, 0x4BE35A, 0x35D0FF, 0x6B7BFF, 0xC46BFF].map { Color(hex: $0) },
        startPoint: .leading, endPoint: .trailing)
}

extension Comparable {
    /// Clamp helper used by the layout maths.
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}
