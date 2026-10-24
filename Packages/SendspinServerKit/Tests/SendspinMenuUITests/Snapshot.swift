import AppKit
import SwiftUI
import Testing

/// Snapshot tests: a view rendered at a fixed 2x, in a fixed appearance, compared with the image
/// recorded for it in `__Snapshots__` beside the test.
///
/// The first run records the image (and fails, so a new image is looked at before it's kept).
/// `SNAPSHOT_RECORD=1 swift test` records them all again. When an image differs, the new one is
/// written next to it as `<name>.actual.png`, to compare. Rendering differs a little between
/// macOS versions, with the system's accent colour (the images use the default, blue) and with
/// the screen's scale (text is drawn at it: the images are from a Retina screen), so these tests
/// run on a Mac with a Retina main screen, not in CI.
@MainActor
enum Snapshot {
    /// Pixels may differ by this much per channel (0…255) without counting: antialiasing.
    static let channelTolerance = 24
    /// And this share of the pixels may differ: the system's text rendering shifts a little.
    static let pixelTolerance = 0.005

    static var isRecording: Bool { ProcessInfo.processInfo.environment["SNAPSHOT_RECORD"] != nil }

    /// Render `view`, as wide as `width`, as tall as it wants, at 2x.
    static func render<V: View>(_ view: V, width: CGFloat, appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: width))
        host.appearance = NSAppearance(named: appearance)
        let size = NSSize(width: width, height: host.fittingSize.height)
        host.frame = NSRect(origin: .zero, size: size)
        // In a window, so SwiftUI lays out and AppKit's controls draw as they do on screen.
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                   pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// Compare with the recorded image `name`, or record it.
    static func assertMatches(_ rep: NSBitmapImageRep, named name: String, filePath: String = #filePath,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let directory = URL(filePath: filePath).deletingLastPathComponent().appending(path: "__Snapshots__")
        let url = directory.appending(path: "\(name).png")
        let actualURL = directory.appending(path: "\(name).actual.png")
        let png = rep.representation(using: .png, properties: [:])!
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard !isRecording, let data = try? Data(contentsOf: url), let recorded = NSBitmapImageRep(data: data) else {
            try? png.write(to: url)
            try? FileManager.default.removeItem(at: actualURL)
            Issue.record("Recorded \(name).png: look at it, then run again", sourceLocation: sourceLocation)
            return
        }
        if let difference = difference(rep, recorded) {
            try? png.write(to: actualURL)
            Issue.record("\(name) differs from its recorded image (\(difference)); the new one is \(name).actual.png",
                         sourceLocation: sourceLocation)
        } else {
            try? FileManager.default.removeItem(at: actualURL)
        }
    }

    /// Why two images differ, or nil when they match within the tolerances.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> String? {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
            return "\(a.pixelsWide)x\(a.pixelsHigh) instead of \(b.pixelsWide)x\(b.pixelsHigh)"
        }
        let pixelsA = rgba(a), pixelsB = rgba(b)
        var differing = 0
        for i in stride(from: 0, to: pixelsA.count, by: 4) {
            for c in 0..<4 where abs(Int(pixelsA[i + c]) - Int(pixelsB[i + c])) > channelTolerance {
                differing += 1
                break
            }
        }
        let share = Double(differing) / Double(pixelsA.count / 4)
        return share > pixelTolerance ? String(format: "%.2f%% of the pixels", share * 100) : nil
    }

    /// The image as RGBA bytes, whatever format it came in.
    private static func rgba(_ rep: NSBitmapImageRep) -> [UInt8] {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}
