import Foundation
import SendspinServerKit

/// Checks that the Sendspin driver hands back what's played into it, unaltered: plays a
/// burst of noise into the device while reading it back with `DriverCapture`, then checks
/// that the burst comes back sample-exact (both channels) and that silence follows it, with
/// no stale ring-buffer audio.
public enum LoopbackCheck {
    public struct Result: Sendable {
        public var sampleRate: Int
        public var signalFrames: Int
        /// Frames of the burst that came back different, or missing.
        public var mismatchedFrames: Int
        /// Non-zero frames read after the burst.
        public var framesAfterBurst: Int
        /// Capture time of the burst's first frame minus its output render time, µs.
        public var offsetUs: Int64?

        public var passed: Bool { mismatchedFrames == 0 && framesAfterBurst == 0 && offsetUs != nil }
    }

    public static func run(device: AudioDevice, seconds: Double = 2) async throws -> Result {
        let capture = try DriverCapture(device: device, blockMs: 10)
        let rate = capture.sampleRate
        let signal = noise(frames: Int(seconds * Double(rate)))
        let reader = Task {
            var samples: [Float] = []
            var firstTimeUs: Int64?
            for await block in capture.blocks {
                if firstTimeUs == nil { firstTimeUs = block.captureTimeUs }
                samples += block.pcm.samples
            }
            return (samples, firstTimeUs ?? 0)
        }
        try capture.start()

        // One burst: the interval is longer than the time it plays.
        let player = try SignalPlayer(device: device, signal: signal, sampleRate: rate,
                                      intervalFrames: signal.count * 4)
        try await Task.sleep(for: .milliseconds(200))
        try player.start()
        try await Task.sleep(for: .seconds(seconds) + .milliseconds(150))
        player.stop()
        try await Task.sleep(for: .milliseconds(750)) // silence after the burst
        capture.stop()
        let (samples, firstTimeUs) = await reader.value

        let channels = DriverCapture.channels
        let frames = samples.count / channels
        let first = (0..<frames).first { samples[$0 * channels] != 0 || samples[$0 * channels + 1] != 0 }
        guard let first else {
            return Result(sampleRate: rate, signalFrames: signal.count, mismatchedFrames: signal.count,
                          framesAfterBurst: 0, offsetUs: nil)
        }
        var mismatched = 0
        for i in 0..<signal.count {
            let frame = first + i
            if frame >= frames || samples[frame * channels] != signal[i] || samples[frame * channels + 1] != signal[i] {
                mismatched += 1
            }
        }
        let after = (first + signal.count..<frames).count(where: {
            samples[$0 * channels] != 0 || samples[$0 * channels + 1] != 0
        })
        let firstUs = firstTimeUs + Int64(first) * 1_000_000 / Int64(rate)
        return Result(sampleRate: rate, signalFrames: signal.count, mismatchedFrames: mismatched,
                      framesAfterBurst: after, offsetUs: player.startTimesUs.first.map { firstUs - $0 })
    }

    /// Repeatable noise, never exactly zero, at a moderate level.
    static func noise(frames: Int) -> [Float32] {
        var state: UInt32 = 1
        return (0..<frames).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            let value = Float32(state >> 8) / Float32(1 << 24) * 0.5 - 0.25
            return value == 0 ? 0.001 : value
        }
    }
}
