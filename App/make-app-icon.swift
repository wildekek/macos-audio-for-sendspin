// Builds the app icon: the Sendspin symbol in paper white on a coral tile, the colours of
// sendspin-audio.com (--ss-coral #E25C4C, --ss-coral-deep #BF493A, --ss-paper #F5F4EC).
// Writes every size macOS uses into the asset catalog, each drawn at its own size.
//
//   swift App/make-app-icon.swift App/MacOSAudioForSendspin/Assets.xcassets/MenuBarIcon.imageset/menubar-icon.svg \
//       App/MacOSAudioForSendspin/Assets.xcassets/AppIcon.appiconset

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let symbol = NSImage(contentsOfFile: arguments[1]) else {
    print("usage: make-app-icon.swift <symbol.svg> <AppIcon.appiconset>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the tile is ~80% of the canvas, corner radius ~22.5% of the tile.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = size * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    shape.addClip()
    NSGradient(starting: color(0xBF493A), ending: color(0xE25C4C))!.draw(in: tile, angle: 90)
    let side = tile.width * 0.6
    let mark = NSRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
    NSImage(size: mark.size, flipped: false) { rect in
        symbol.draw(in: rect)
        color(0xF5F4EC).set()
        rect.fill(using: .sourceAtop)
        return true
    }.draw(in: mark)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(pixels: points * scale).write(to: output.appending(path: file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
print("Wrote \(images.count) sizes to \(output.path)")
