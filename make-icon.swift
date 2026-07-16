import AppKit

let iconsetPath = "/tmp/SOURCR.iconset"
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"

try? FileManager.default.removeItem(atPath: iconsetPath)
try FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16",       16),
    ("icon_16x16@2x",    32),
    ("icon_32x32",       32),
    ("icon_32x32@2x",    64),
    ("icon_128x128",    128),
    ("icon_128x128@2x", 256),
    ("icon_256x256",    256),
    ("icon_256x256@2x", 512),
    ("icon_512x512",    512),
    ("icon_512x512@2x",1024),
]

for spec in specs {
    let size = CGFloat(spec.px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.2
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    // VS Code-ish deep blue
    NSColor(red: 0.10, green: 0.22, blue: 0.42, alpha: 1.0).setFill()
    path.fill()

    let letter = "S"
    let fontSize = size * 0.58
    let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let textSize = letter.size(withAttributes: attrs)
    let point = NSPoint(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 - size * 0.02
    )
    letter.draw(at: point, withAttributes: attrs)

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to render \(spec.name)")
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
    print("iconutil failed with status \(process.terminationStatus)")
}

try? FileManager.default.removeItem(atPath: iconsetPath)
