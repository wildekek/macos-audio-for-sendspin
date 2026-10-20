// Builds the app icon, which is also the driver's device icon: a bookshelf speaker on a graphite
// tile. No Sendspin logo or colours: those are the Open Home Foundation's trademarks.
// Each size is drawn at its own size, with the finer details left out where they'd be mush.
//
//   swift App/make-app-icon.swift App/MacOSAudioForSendspin/Assets.xcassets/AppIcon.appiconset
//   swift App/make-app-icon.swift Driver/resources/SendspinDevice.icns

import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: make-app-icon.swift <AppIcon.appiconset | out.icns>")
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])
let icns = output.pathExtension == "icns"
let folder = icns ? output.deletingPathExtension().appendingPathExtension("iconset") : output
if icns { try? FileManager.default.removeItem(at: folder) }
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

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
    // Drawn on a 100-unit grid, origin bottom left.
    let u = size / 100
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: (x - r) * u, y: (y - r) * u, width: 2 * r * u, height: 2 * r * u))
    }
    // macOS icon grid: the tile is 80% of the canvas, corner radius 22.5% of the tile.
    let tile = NSBezierPath(roundedRect: NSRect(x: 10 * u, y: 10 * u, width: 80 * u, height: 80 * u),
                            xRadius: 18 * u, yRadius: 18 * u)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 2 * u
    shadow.shadowOffset = NSSize(width: 0, height: -0.8 * u)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x1D2025), ending: color(0x3A3F48))!.draw(in: tile, angle: 90)

    let cone = color(0x262A30), accent = color(0xF2A541)
    color(0xEEEBE4).setFill()
    NSBezierPath(roundedRect: NSRect(x: 31 * u, y: 19 * u, width: 38 * u, height: 62 * u),
                 xRadius: 7 * u, yRadius: 7 * u).fill()
    // Tweeter above, woofer below; their centres and the woofer's surround only where they show.
    if pixels >= 32 {
        cone.setFill()
        circle(50, 67, 6).fill()
    }
    if pixels >= 64 {
        accent.setFill()
        circle(50, 67, 2.2).fill()
    }
    cone.setFill()
    circle(50, 40, 13.5).fill()
    if pixels >= 128 {
        color(0x4B515B).setStroke()
        let surround = circle(50, 40, 9.5)
        surround.lineWidth = 1.2 * u
        surround.stroke()
    }
    if pixels >= 32 {
        accent.setFill()
        circle(50, 40, 4.2).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(pixels: points * scale).write(to: folder.appending(path: file))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": file])
    }
}
if icns {
    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", folder.path, "-o", output.path]
    try! iconutil.run()
    iconutil.waitUntilExit()
    try? FileManager.default.removeItem(at: folder)
    print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
} else {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appending(path: "Contents.json"))
    print("Wrote \(images.count) sizes to \(output.path)")
}
