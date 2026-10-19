// Builds SendspinDevice.icns: the Sendspin symbol in black on a light rounded tile.
// Device icons aren't template images, so the tile keeps the monochrome symbol
// readable on both light and dark backgrounds.
//
//   swift Driver/resources/make-icon.swift <symbol.svg> <out.icns>

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3, let symbol = NSImage(contentsOfFile: arguments[1]) else {
    print("usage: make-icon.swift <symbol.svg> <out.icns>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[2])
let iconset = output.deletingPathExtension().appendingPathExtension("iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the tile is ~80% of the canvas, corner radius ~22% of the tile.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSColor(white: 0.97, alpha: 1).setFill()
    path.fill()
    NSColor(white: 0.78, alpha: 1).setStroke()
    path.lineWidth = max(1, size / 256)
    path.stroke()
    // The symbol SVG is square with the logo centred, so it scales without distortion.
    let glyph = tile.insetBy(dx: tile.width * 0.16, dy: tile.width * 0.16)
    symbol.draw(in: glyph)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "wrote \(output.path)" : "iconutil failed")
