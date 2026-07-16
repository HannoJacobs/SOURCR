import AppKit
import Foundation

/// SOURCR app icon — git branch fork + side-by-side diff bars (no lettermark).
let iconsetPath = "/tmp/SOURCR.iconset"
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

try? FileManager.default.removeItem(atPath: iconsetPath)
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func drawIcon(in size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 0.223
    let bg = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)

    // Deep slate → indigo fill (reads as “source control”, not generic purple).
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.28, alpha: 1),
        NSColor(calibratedRed: 0.12, green: 0.22, blue: 0.42, alpha: 1),
    ])!
    gradient.draw(in: bg, angle: 90)

    // Soft inner rim so the glyph pops on light Finder backgrounds.
    let inset = size * 0.035
    let rim = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: corner * 0.9, yRadius: corner * 0.9)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    rim.lineWidth = max(1, size * 0.012)
    rim.stroke()

    // Coordinate helpers in unit space [0,1], flipped for AppKit (y-up).
    func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: x * size, y: y * size)
    }

    let lineW = max(1.5, size * 0.075)
    let nodeR = max(2.0, size * 0.078)

    // --- Diff bars (right): deletion / addition columns ---
    if size >= 32 {
        let barW = size * 0.07
        let barH = size * 0.34
        let barY = size * 0.33
        let redX = size * 0.70
        let greenX = size * 0.80

        let red = NSBezierPath(roundedRect: NSRect(x: redX, y: barY, width: barW, height: barH),
                               xRadius: barW * 0.35, yRadius: barW * 0.35)
        NSColor(calibratedRed: 0.95, green: 0.38, blue: 0.42, alpha: 0.92).setFill()
        red.fill()

        // Green bar slightly shorter / offset — reads as a side-by-side hunk.
        let green = NSBezierPath(roundedRect: NSRect(x: greenX, y: barY + size * 0.05, width: barW, height: barH * 0.78),
                                 xRadius: barW * 0.35, yRadius: barW * 0.35)
        NSColor(calibratedRed: 0.32, green: 0.78, blue: 0.48, alpha: 0.92).setFill()
        green.fill()
    }

    // --- Branch glyph (left-center) ---
    NSColor.white.setStroke()
    NSColor.white.setFill()

    let stem = NSBezierPath()
    stem.lineWidth = lineW
    stem.lineCapStyle = .round
    stem.lineJoinStyle = .round
    stem.move(to: P(0.30, 0.18))
    stem.line(to: P(0.30, 0.55))
    stem.stroke()

    // Fork curve up-right to tip branch.
    let fork = NSBezierPath()
    fork.lineWidth = lineW
    fork.lineCapStyle = .round
    fork.lineJoinStyle = .round
    fork.move(to: P(0.30, 0.55))
    fork.curve(to: P(0.52, 0.80), controlPoint1: P(0.30, 0.70), controlPoint2: P(0.38, 0.80))
    fork.stroke()

    // Side branch left tip.
    let side = NSBezierPath()
    side.lineWidth = lineW
    side.lineCapStyle = .round
    side.move(to: P(0.30, 0.42))
    side.curve(to: P(0.48, 0.28), controlPoint1: P(0.38, 0.42), controlPoint2: P(0.44, 0.34))
    side.stroke()

    func node(at p: NSPoint) {
        let r = nodeR
        let oval = NSBezierPath(ovalIn: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        NSColor.white.setFill()
        oval.fill()
        // Hollow center so nodes read as git “commits” not blobs.
        let inner = NSBezierPath(ovalIn: NSRect(x: p.x - r * 0.42, y: p.y - r * 0.42, width: r * 0.84, height: r * 0.84))
        NSColor(calibratedRed: 0.10, green: 0.18, blue: 0.36, alpha: 1).setFill()
        inner.fill()
    }

    node(at: P(0.30, 0.18)) // root
    node(at: P(0.30, 0.55)) // fork point
    node(at: P(0.52, 0.80)) // tip
    node(at: P(0.48, 0.28)) // side tip

    // Tiny accent on tip node for ≥64px — suggests “HEAD / current”.
    if size >= 64 {
        let tip = P(0.52, 0.80)
        let halo = NSBezierPath(ovalIn: NSRect(
            x: tip.x - nodeR * 1.55,
            y: tip.y - nodeR * 1.55,
            width: nodeR * 3.1,
            height: nodeR * 3.1
        ))
        NSColor(calibratedRed: 0.45, green: 0.75, blue: 1.0, alpha: 0.35).setStroke()
        halo.lineWidth = max(1, size * 0.018)
        halo.stroke()
    }

    image.unlockFocus()
    return image
}

for spec in specs {
    let image = drawIcon(in: CGFloat(spec.px))

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to render \(spec.name)\n", stderr)
        continue
    }

    let filePath = "\(iconsetPath)/\(spec.name).png"
    try png.write(to: URL(fileURLWithPath: filePath))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetPath, "-o", outputPath]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Created \(outputPath)")
} else {
    fputs("iconutil failed with status \(process.terminationStatus)\n", stderr)
    exit(1)
}

try? FileManager.default.removeItem(atPath: iconsetPath)
