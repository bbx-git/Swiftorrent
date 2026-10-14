// Draws the app icon and writes App/Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift   (run from the repo root)
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let u = s / 1024

    // Tile on the standard macOS icon grid (824 pt square inside 1024).
    let tile = CGRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * u, yRadius: 185 * u)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * u), blur: 24 * u,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    tilePath.fill()
    ctx.restoreGState()

    ctx.saveGState()
    tilePath.addClip()
    let gradient = NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0, alpha: 1)])!
    gradient.draw(from: CGPoint(x: tile.midX, y: tile.maxY), to: CGPoint(x: tile.midX, y: tile.minY), options: [])
    ctx.restoreGState()

    // White download arrow over a tray.
    NSColor.white.setFill()
    let cx = 512 * u
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: cx - 70 * u, y: 760 * u))
    arrow.line(to: CGPoint(x: cx + 70 * u, y: 760 * u))
    arrow.line(to: CGPoint(x: cx + 70 * u, y: 520 * u))
    arrow.line(to: CGPoint(x: cx + 190 * u, y: 520 * u))
    arrow.line(to: CGPoint(x: cx, y: 330 * u))
    arrow.line(to: CGPoint(x: cx - 190 * u, y: 520 * u))
    arrow.line(to: CGPoint(x: cx - 70 * u, y: 520 * u))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 36 * u
    arrow.fill()
    NSColor.white.setStroke()
    arrow.stroke()

    NSBezierPath(roundedRect: CGRect(x: cx - 260 * u, y: 230 * u, width: 520 * u, height: 56 * u),
                 xRadius: 28 * u, yRadius: 28 * u).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "tmp/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "App/Resources/AppIcon.icns"]
try p.run()
p.waitUntilExit()
exit(p.terminationStatus)
