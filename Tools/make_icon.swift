// Renders the 1024x1024 app icon: a heart built from beveled blocks on a deep blue gradient.
// Usage: swift Tools/make_icon.swift BlockBliss/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import AppKit
import CoreGraphics

let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func mix(_ hex: UInt32, with other: UInt32, _ t: CGFloat) -> CGColor {
    func c(_ h: UInt32, _ s: UInt32) -> CGFloat { CGFloat((h >> s) & 0xFF) / 255 }
    return CGColor(srgbRed: c(hex, 16) * (1 - t) + c(other, 16) * t,
                   green: c(hex, 8) * (1 - t) + c(other, 8) * t,
                   blue: c(hex, 0) * (1 - t) + c(other, 0) * t, alpha: 1)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError() }

// CoreGraphics origin is bottom-left; flip so rows go top-down.
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)

// Background gradient (opaque — iOS icons must not have alpha).
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x4A6FD0), rgb(0x2B3F8F), rgb(0x1E2B66)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: CGFloat(size)), options: [])

// Soft glow behind the heart.
let glow = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.55, blue: 0.75, alpha: 0.35),
                                                   CGColor(srgbRed: 1, green: 0.55, blue: 0.75, alpha: 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 500), endRadius: 470, options: [])

let heart = [
    ".XX.XX.",
    "XXXXXXX",
    "XXXXXXX",
    ".XXXXX.",
    "..XXX..",
    "...X...",
]
// Warm palette that sweeps across the heart like a row of mixed pieces.
let palette: [UInt32] = [0xFF4D6D, 0xFF7A3D, 0xFFC93D, 0x4CD964, 0x3DC8FF, 0x5B7BFF, 0xB35BFF]

let cell: CGFloat = 112
let gap: CGFloat = 4
let cols = heart[0].count, rows = heart.count
let gridW = CGFloat(cols) * cell, gridH = CGFloat(rows) * cell
let ox = (CGFloat(size) - gridW) / 2
let oy = (CGFloat(size) - gridH) / 2 + 20

func drawBlock(_ r: CGRect, _ base: UInt32) {
    let bevel = r.width * 0.13
    // Base
    ctx.setFillColor(rgb(base)); ctx.fill(r)
    // Top bevel (light)
    ctx.setFillColor(mix(base, with: 0xFFFFFF, 0.45))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.minY))
    ctx.addLine(to: CGPoint(x: r.maxX - bevel, y: r.minY + bevel)); ctx.addLine(to: CGPoint(x: r.minX + bevel, y: r.minY + bevel))
    ctx.closePath(); ctx.fillPath()
    // Left bevel (mid-light)
    ctx.setFillColor(mix(base, with: 0xFFFFFF, 0.22))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX + bevel, y: r.minY + bevel))
    ctx.addLine(to: CGPoint(x: r.minX + bevel, y: r.maxY - bevel)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
    ctx.closePath(); ctx.fillPath()
    // Right bevel (mid-dark)
    ctx.setFillColor(mix(base, with: 0x000000, 0.18))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    ctx.addLine(to: CGPoint(x: r.maxX - bevel, y: r.maxY - bevel)); ctx.addLine(to: CGPoint(x: r.maxX - bevel, y: r.minY + bevel))
    ctx.closePath(); ctx.fillPath()
    // Bottom bevel (dark)
    ctx.setFillColor(mix(base, with: 0x000000, 0.34))
    ctx.beginPath()
    ctx.move(to: CGPoint(x: r.minX, y: r.maxY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    ctx.addLine(to: CGPoint(x: r.maxX - bevel, y: r.maxY - bevel)); ctx.addLine(to: CGPoint(x: r.minX + bevel, y: r.maxY - bevel))
    ctx.closePath(); ctx.fillPath()
    // Face gloss
    let face = r.insetBy(dx: bevel, dy: bevel)
    let gloss = CGGradient(colorsSpace: space, colors: [mix(base, with: 0xFFFFFF, 0.18), rgb(base)] as CFArray,
                           locations: [0, 1])!
    ctx.saveGState(); ctx.clip(to: face)
    ctx.drawLinearGradient(gloss, start: CGPoint(x: face.minX, y: face.minY), end: CGPoint(x: face.minX, y: face.maxY), options: [])
    ctx.restoreGState()
}

// Drop shadow for the whole heart.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: CGColor(srgbRed: 0, green: 0, blue: 0.1, alpha: 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
for (r, line) in heart.enumerated() {
    for (c, ch) in line.enumerated() where ch == "X" {
        let rect = CGRect(x: ox + CGFloat(c) * cell + gap / 2, y: oy + CGFloat(r) * cell + gap / 2,
                          width: cell - gap, height: cell - gap)
        let idx = min(palette.count - 1, max(0, (c + r) * palette.count / (cols + rows - 4)))
        drawBlock(rect, palette[idx])
    }
}
ctx.endTransparencyLayer()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("render failed") }
let rep = NSBitmapImageRep(cgImage: image)
// Strip alpha: App Store / springboard icons must be opaque.
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png failed") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
