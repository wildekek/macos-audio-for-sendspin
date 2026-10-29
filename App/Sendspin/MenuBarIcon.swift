import AppKit
import Observation

/// The menu bar icon: Sendspin's S, with its waves while the Mac's sound goes out
/// (`BridgeController.isPlaying`). Starting, the S turns a half turn clockwise as the inner, then
/// the outer waves fade in; stopping, it turns back as they fade out, outer first. The S is the
/// same after a half turn, so it lands where it started. A menu bar label can't be transformed, so
/// while it moves this draws each frame; at rest, and with Reduce Motion, it's the vector assets.
@MainActor
@Observable
final class MenuBarIcon {
    private(set) var image: NSImage
    private(set) var isPlaying: Bool

    @ObservationIgnored private let bridge: BridgeController
    @ObservationIgnored private var turn = Channel(at: 0)
    @ObservationIgnored private var inner = Channel(at: 0)
    @ObservationIgnored private var outer = Channel(at: 0)
    @ObservationIgnored private var timer: Timer?

    init(bridge: BridgeController) {
        let playing = bridge.isPlaying
        self.bridge = bridge
        isPlaying = playing
        image = Self.rest(playing: playing)
        let value: Double = playing ? 1 : 0
        (turn, inner, outer) = (Channel(at: value), Channel(at: value), Channel(at: value))
        observe()
    }

    private func observe() {
        withObservationTracking { _ = bridge.isPlaying } onChange: { [weak self] in
            // Called before the change: read it once it's made.
            Task { @MainActor in
                self?.playingChanged()
                self?.observe()
            }
        }
    }

    private func playingChanged() {
        guard bridge.isPlaying != isPlaying else { return }
        isPlaying = bridge.isPlaying
        let target: Double = isPlaying ? 1 : 0
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            (turn, inner, outer) = (Channel(at: target), Channel(at: target), Channel(at: target))
            stop()
            return
        }
        // From where it is, so a change halfway turns back from there.
        let now = Date.now
        turn = Channel(from: turn.value(at: now), to: target, start: now, duration: 0.7, curve: .turn)
        inner = Channel(from: inner.value(at: now), to: target, start: now + (isPlaying ? 0 : 0.14),
                        duration: 0.22, curve: .easeOut)
        outer = Channel(from: outer.value(at: now), to: target, start: now + (isPlaying ? 0.14 : 0),
                        duration: 0.22, curve: .easeOut)
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            // .common: it keeps turning while the menu is open.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        tick()
    }

    private func tick() {
        let now = Date.now
        guard [turn, inner, outer].contains(where: { !$0.isDone(at: now) }) else {
            stop()
            return
        }
        image = Self.frame(turn: turn.value(at: now), inner: inner.value(at: now), outer: outer.value(at: now))
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        image = Self.rest(playing: isPlaying)
    }

    private static func rest(playing: Bool) -> NSImage {
        NSImage(named: playing ? "MenuBarIconPlaying" : "MenuBarIcon")!
    }

    /// `turn` 0–1 is 0–180° clockwise; `inner` and `outer` are the waves' opacity.
    private static func frame(turn: Double, inner: Double, outer: Double) -> NSImage {
        let parts = ["MenuBarIcon", "MenuBarIconInnerWaves", "MenuBarIconOuterWaves"].map { NSImage(named: $0)! }
        let image = NSImage(size: parts[0].size, flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: -180 * turn)
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()
            for (part, opacity) in zip(parts, [1, inner, outer]) where opacity > 0 {
                part.draw(in: rect, from: .zero, operation: .sourceOver, fraction: opacity)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// One value moving from `from` to `to`, as a CSS transition does.
private struct Channel {
    var from: Double
    var to: Double
    var start: Date
    var duration: TimeInterval
    var curve: Curve

    init(from: Double, to: Double, start: Date, duration: TimeInterval, curve: Curve) {
        (self.from, self.to, self.start, self.duration, self.curve) = (from, to, start, duration, curve)
    }

    init(at value: Double) {
        self.init(from: value, to: value, start: .distantPast, duration: 0, curve: .easeOut)
    }

    func value(at now: Date) -> Double {
        guard duration > 0 else { return to }
        let t = min(max(now.timeIntervalSince(start) / duration, 0), 1)
        return from + (to - from) * curve.value(at: t)
    }

    func isDone(at now: Date) -> Bool { now >= start + duration }
}

/// A CSS cubic-bezier timing curve.
private struct Curve {
    let x1, y1, x2, y2: Double

    /// The half turn: quick to start, slow to settle.
    static let turn = Curve(x1: 0.3, y1: 0, x2: 0.2, y2: 1)
    static let easeOut = Curve(x1: 0, y1: 0, x2: 0.58, y2: 1)

    func value(at t: Double) -> Double {
        func bezier(_ a: Double, _ b: Double, _ s: Double) -> Double {
            3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s
        }
        // x(s) rises with s: find the s where it's t, then its y.
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if bezier(x1, x2, mid) < t { low = mid } else { high = mid }
        }
        return bezier(y1, y2, (low + high) / 2)
    }
}
