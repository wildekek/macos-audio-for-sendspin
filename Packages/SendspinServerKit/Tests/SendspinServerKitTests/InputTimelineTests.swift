import Foundation
import Testing
@testable import SendspinServerKit

struct InputTimelineTests {
    /// 20 ms stereo chunks of a constant level, timestamped as a source whose clock runs `ppm`
    /// slow (positive) or fast against ours, with ±200 µs of jitter from its time filter.
    static func run(ppm: Double, seconds: Int) -> (timeline: InputTimeline, times: [Int64], frames: [Int]) {
        var timeline = InputTimeline(sampleRate: 48_000, channels: 2)
        var random = SystemRandomNumberGenerator()
        var times: [Int64] = [], frames: [Int] = []
        let chunk = [Float](repeating: 0.25, count: 960 * 2)
        for index in 0..<(seconds * 50) {
            let realUs = Double(index) * 20_000 * (1 + ppm / 1_000_000)
            let jitter = Int64.random(in: -200...200, using: &random)
            let placed = timeline.place(chunk, timestampUs: 5_000_000 + Int64(realUs) + jitter)
            #expect(placed.samples.allSatisfy { abs($0 - 0.25) < 1e-6 })
            times.append(placed.captureTimeUs)
            frames.append(placed.samples.count / 2)
        }
        return (timeline, times, frames)
    }

    @Test func aSteadySourceIsLeftAlone() {
        let (timeline, times, _) = Self.run(ppm: 0, seconds: 10)
        #expect(timeline.corrections == 0)
        #expect(abs(times[0] - (5_000_000 + InputTimeline.delayUs)) <= 200)
        // Timed by the sample count: exactly 20 ms apart.
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 == 20_000 })
    }

    /// 100 ppm over a minute is 6 ms, 288 frames; past the first 0.5 ms they're absorbed, and the
    /// timeline keeps within the tolerance.
    @Test(arguments: [100.0, -100.0])
    func driftIsAbsorbedFrameByFrame(ppm: Double) {
        let (timeline, _, frames) = Self.run(ppm: ppm, seconds: 60)
        #expect((250...280).contains(timeline.corrections))
        #expect(abs(timeline.driftUs) < InputTimeline.toleranceUs + 100)
        let expected = ppm > 0 ? 961 : 959
        #expect(frames.allSatisfy { $0 == 960 || $0 == expected })
    }

    @Test func aGapStartsOver() {
        var timeline = InputTimeline(sampleRate: 48_000, channels: 1)
        let chunk = [Float](repeating: 0, count: 960)
        _ = timeline.place(chunk, timestampUs: 1_000_000)
        #expect(timeline.place(chunk, timestampUs: 1_020_000).captureTimeUs == 1_020_000 + InputTimeline.delayUs)
        #expect(timeline.place(chunk, timestampUs: 3_000_000).captureTimeUs == 3_000_000 + InputTimeline.delayUs)
    }

    /// A dropped or doubled frame is crossfaded: a ramp stays a smooth ramp.
    @Test func correctionsCrossfade() {
        let ramp = (0..<200).map { Float($0) }
        let dropped = InputTimeline.dropFrame(ramp, channels: 1)
        let doubled = InputTimeline.doubleFrame(ramp, channels: 1)
        #expect(dropped.count == 199 && doubled.count == 201)
        #expect(dropped.last == 199 && doubled.last == 199 && doubled.first == 0)
        for signal in [dropped, doubled] {
            #expect(zip(signal, signal.dropFirst()).allSatisfy { $1 - $0 >= 0 && $1 - $0 <= 1 + 1.0 / 64 })
        }
    }
}
