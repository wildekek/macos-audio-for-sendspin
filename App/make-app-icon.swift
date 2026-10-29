// Builds the app icon, which is also the driver's device icon: Sendspin's mark in cream on a
// coral tile, the brand colour, as the Music Assistant and Home Assistant apps do. The mark comes
// from sendspin-logo.svg beside this script (Sendspin/sendspin-audio.com's logo).
//
//   swift App/make-app-icon.swift App/Sendspin/Assets.xcassets/AppIcon.appiconset
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

// The logo's paths, in its own coordinates (115 × 94, y down). It only uses absolute M, L, H,
// V, C and Z.
let logo = try! String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "sendspin-logo.svg"), encoding: .utf8)
let logoSize = CGSize(width: 115, height: 94)
let mark: CGPath = {
    let path = CGMutablePath()
    for match in logo.matches(of: #/<path d="([^"]+)"/#) {
        let data = String(match.1)
        var tokens: [String] = []
        for token in data.matches(of: #/[MLHVCZ]|-?[0-9]*\.?[0-9]+/#) { tokens.append(String(token.0)) }
        var i = 0, command = "M", current = CGPoint.zero
        func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
        func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
        while i < tokens.count {
            if tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
            switch command {
            case "M": current = point(); path.move(to: current); command = "L"
            case "L": current = point(); path.addLine(to: current)
            case "H": current.x = number(); path.addLine(to: current)
            case "V": current.y = number(); path.addLine(to: current)
            case "C":
                let c1 = point(), c2 = point()
                current = point()
                path.addCurve(to: current, control1: c1, control2: c2)
            default: path.closeSubpath()
            }
        }
    }
    return path
}()

func render(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Drawn on a 100-unit grid, origin bottom left.
    let u = size / 100
    // macOS icon grid: the tile is 80% of the canvas, corner radius 22.5% of the tile.
    let tile = NSBezierPath(roundedRect: NSRect(x: 10 * u, y: 10 * u, width: 80 * u, height: 80 * u),
                            xRadius: 18 * u, yRadius: 18 * u)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 2 * u
    shadow.shadowOffset = NSSize(width: 0, height: -0.8 * u)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(0xE25C4C).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    // The mark 70% of the tile wide, centred, flipped to y up.
    let context = NSGraphicsContext.current!.cgContext
    let scale = 56 * u / logoSize.width
    context.translateBy(x: 50 * u - 56 * u / 2, y: 50 * u + logoSize.height * scale / 2)
    context.scaleBy(x: scale, y: -scale)
    context.addPath(mark)
    context.setFillColor(color(0xF5F4EC).cgColor)
    context.fillPath()
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
