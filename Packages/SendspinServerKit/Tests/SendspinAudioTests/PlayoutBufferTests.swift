import Testing
@testable import SendspinAudio

struct PlayoutBufferTests {
    static let rate = 48_000
    static let renderFrames = 512
    /// When frame 1 is due, on the server clock.
    static let startUs: Int64 = 10_000_000

    /// Frames numbered from `first`: left is the number, right its negative. 0 is silence.
    static func frames(_ first: Int, count: Int) -> [Float] {
        (0..<count).flatMap { i -> [Float] in [Float(first + i), -Float(first + i)] }
    }

    /// When frame `number` is due.
    static func dueUs(_ number: Int) -> Double {
        Double(startUs) + Double(number - 1) * 1_000_000 / Double(rate)
    }

    static func write(_ buffer: PlayoutBuffer, from first: Int, count: Int, atUs: Int64? = nil) {
        let samples = frames(first, count: count)
        let timeUs = atUs ?? Int64(dueUs(first).rounded())
        samples.withUnsafeBufferPointer { buffer.write($0, timestampUs: timeUs) }
    }

    static func render(_ buffer: PlayoutBuffer, atUs outputUs: Double, frames: Int = renderFrames) -> [Float] {
        var output = [Float](repeating: .nan, count: frames * 2)
        output.withUnsafeMutableBufferPointer {
            buffer.render(into: $0.baseAddress!, frames: frames, outputUs: outputUs)
        }
        return output
    }

    /// Left samples only: the frame numbers.
    static func numbers(_ output: [Float]) -> [Int] {
        stride(from: 0, to: output.count, by: 2).map { Int(output[$0]) }
    }

    @Test func waitsInSilenceUntilTheFirstFrameIsDue() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        Self.write(buffer, from: 1, count: 4_800)
        // 30 ms early: 1,440 frames of silence, spread over three renders.
        var heard: [Int] = []
        var outputUs = Self.dueUs(1) - 30_000
        for _ in 0..<4 {
            heard += Self.numbers(Self.render(buffer, atUs: outputUs))
            outputUs += Double(Self.renderFrames) * 1_000_000 / Double(Self.rate)
        }
        let first = heard.firstIndex { $0 != 0 }
        #expect(first == 1_440)
        #expect(heard[1_440...].prefix(100) == ArraySlice(1...100))
        #expect(buffer.counters.snaps == 1)
    }

    @Test func dropsWhatIsLateAtTheStart() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        Self.write(buffer, from: 1, count: 4_800)
        // 10 ms late: the first 480 frames are skipped.
        let heard = Self.numbers(Self.render(buffer, atUs: Self.dueUs(1) + 10_000))
        #expect(heard.first == 481)
        #expect(heard == Array(481..<481 + Self.renderFrames))
    }

    @Test func playsSilenceUntilAudioArrives() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        #expect(Self.numbers(Self.render(buffer, atUs: 0)).allSatisfy { $0 == 0 })
        #expect(buffer.counters == PlayoutBuffer.Counters())
    }

    /// The output's clock runs 100 ppm off the server's, and its timestamps jitter by up to
    /// ±30 µs: a minute of audio stays within the dead band plus a frame or two, by dropping
    /// or repeating single frames, never more than 0.5% of them.
    @Test(arguments: [100.0, -100.0])
    func followsADriftingOutputClock(ppm: Double) {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        var generator = SplitMix(seed: 7)
        let blockFrames = 960
        var written = 1
        Self.write(buffer, from: written, count: blockFrames * 15)
        written += blockFrames * 15
        // How long one render lasts on the server clock, the output's clock being off.
        let renderUs = Double(Self.renderFrames) * 1_000_000 / Double(Self.rate) / (1 + ppm / 1_000_000)
        var outputUs = Self.dueUs(1) - 5_000
        var worstErrorUs = 0.0
        var settledWorstUs = 0.0
        for render in 0..<(60 * Self.rate / Self.renderFrames) {
            let jitterUs = (generator.unit() * 2 - 1) * 30
            let heard = Self.numbers(Self.render(buffer, atUs: outputUs + jitterUs))
            // Keep 300 ms queued, in 20 ms blocks, as the group sends them.
            while Double(written) < Double(Self.rate) * ((outputUs - Self.dueUs(1)) / 1_000_000 + 0.3) {
                Self.write(buffer, from: written, count: blockFrames)
                written += blockFrames
            }
            // The last frame of the render, so a repeated first frame doesn't count.
            if let last = heard.last, last > 0 {
                let errorUs = outputUs + Double(Self.renderFrames - 1) * renderUs / Double(Self.renderFrames)
                    - Self.dueUs(last)
                worstErrorUs = max(worstErrorUs, abs(errorUs))
                if render > 500 { settledWorstUs = max(settledWorstUs, abs(errorUs)) }
            }
            outputUs += renderUs
        }
        let counters = buffer.counters
        #expect(counters.snaps == 1)
        #expect(counters.underruns == 0)
        #expect(worstErrorUs < 1_000)
        #expect(settledWorstUs < PlayoutBuffer.deadBandUs + 100)
        // 100 ppm of a minute is 288 frames; whichever way, about that many are corrected.
        let corrected = ppm > 0 ? counters.repeatedFrames : counters.droppedFrames
        let other = ppm > 0 ? counters.droppedFrames : counters.repeatedFrames
        #expect((260...320).contains(corrected))
        #expect(other < 20)
    }

    @Test func catchesUpInOneShotAfterAnUnderrun() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        Self.write(buffer, from: 1, count: 1_024)
        let renderUs = Double(Self.renderFrames) * 1_000_000 / Double(Self.rate)
        var outputUs = Self.dueUs(1)
        _ = Self.render(buffer, atUs: outputUs)
        outputUs += renderUs
        _ = Self.render(buffer, atUs: outputUs)
        outputUs += renderUs
        // Starved for two renders.
        #expect(Self.numbers(Self.render(buffer, atUs: outputUs)).allSatisfy { $0 == 0 })
        outputUs += renderUs
        _ = Self.render(buffer, atUs: outputUs)
        outputUs += renderUs
        #expect(buffer.counters.underruns == 1)
        // The audio that follows arrives; what was due meanwhile is skipped.
        Self.write(buffer, from: 1_025, count: 9_600)
        let heard = Self.numbers(Self.render(buffer, atUs: outputUs))
        #expect(heard.first == 2_049)
        #expect(buffer.counters.snaps == 2)
    }

    @Test func fillsAShortGapWithSilence() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        Self.write(buffer, from: 1, count: 960)
        // 5 ms (240 frames) after the first block ends.
        Self.write(buffer, from: 961, count: 960, atUs: Int64(Self.dueUs(961).rounded()) + 5_000)
        #expect(buffer.queuedFrames == 960 + 240 + 960)
        var heard = Self.numbers(Self.render(buffer, atUs: Self.dueUs(1), frames: 2_160))
        #expect(heard[959] == 960)
        #expect(heard[960..<1_200].allSatisfy { $0 == 0 })
        #expect(heard[1_200] == 961)
        heard = Self.numbers(Self.render(buffer, atUs: Self.dueUs(1) + 45_000, frames: 16))
        #expect(heard.allSatisfy { $0 == 0 })
    }

    @Test func startsOverOnAJumpBack() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        Self.write(buffer, from: 1, count: 960)
        Self.write(buffer, from: 5_000, count: 960, atUs: Self.startUs - 100_000)
        #expect(buffer.queuedFrames == 960)
        let heard = Self.numbers(Self.render(buffer, atUs: Double(Self.startUs - 100_000)))
        #expect(heard.first == 5_000)
    }

    @Test func resetForgetsTheQueue() {
        let buffer = PlayoutBuffer(sampleRate: Self.rate)
        Self.write(buffer, from: 1, count: 960)
        buffer.reset()
        #expect(buffer.queuedFrames == 0)
        #expect(Self.numbers(Self.render(buffer, atUs: Self.dueUs(1))).allSatisfy { $0 == 0 })
        #expect(buffer.counters.underruns == 0)
    }

    @Test func correctsByAbout21MicrosecondsAtAnyRate() {
        #expect(PlayoutBuffer(sampleRate: 44_100).correctionFrames == 1)
        #expect(PlayoutBuffer(sampleRate: 48_000).correctionFrames == 1)
        #expect(PlayoutBuffer(sampleRate: 96_000).correctionFrames == 2)
        #expect(PlayoutBuffer(sampleRate: 192_000).correctionFrames == 4)
    }
}

/// A small deterministic generator for the jitter.
private struct SplitMix {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}
