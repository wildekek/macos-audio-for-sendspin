import Testing
@testable import SendspinAudio

struct CaptureAssemblerTests {
    static let rate = 48_000
    /// 20 ms at 48 kHz.
    static let blockFrames = 960

    /// A sample time's server-clock time, for tests: 0 µs at sample 0.
    static func time(_ sampleTime: Int64) -> Int64? { sampleTime * 1_000_000 / Int64(rate) }
    static func noTime(_: Int64) -> Int64? { nil }
    static func now() -> Int64 { 123_456_789 }

    /// Frames whose left sample is their sample time, and right its negative.
    static func reply(start: Int64, frames: Int, session: Int64 = 1, rate: Int = rate) -> DriverReply {
        let samples = (0..<frames).flatMap { i -> [Float] in
            let t = Float(start + Int64(i))
            return [t, -t]
        }
        return DriverReply(start: start, session: session, rate: rate, samples: samples)
    }

    /// An assembler that has started its timeline (session 1).
    static func started() -> CaptureAssembler {
        var assembler = CaptureAssembler(sampleRate: rate, channels: 2, blockMs: 20)
        _ = assembler.take(reply(start: 0, frames: 0), time: time, now: now)
        return assembler
    }

    @Test func theFirstReplyStartsTheTimelineFromTheNewestFrame() {
        var assembler = CaptureAssembler(sampleRate: Self.rate, channels: 2, blockMs: 20)
        #expect(assembler.nextSampleTime == -1)
        let output = assembler.take(Self.reply(start: 5_000, frames: 2_000), time: Self.time, now: Self.now)
        #expect(output.timeline == .started)
        #expect(output.blocks.isEmpty)
        #expect(assembler.nextSampleTime == -1)
    }

    @Test func cutsFixedBlocksWithContiguousTimesAndSamples() {
        var assembler = Self.started()
        var blocks = assembler.take(Self.reply(start: 4_800, frames: 2_500), time: Self.time, now: Self.now).blocks
        blocks += assembler.take(Self.reply(start: 7_300, frames: 2_000), time: Self.time, now: Self.now).blocks
        #expect(blocks.count == 4)
        for (i, block) in blocks.enumerated() {
            let start = 4_800 + Int64(i * Self.blockFrames)
            #expect(block.pcm.frameCount == Self.blockFrames)
            #expect(block.pcm.sampleRate == Self.rate)
            #expect(block.captureTimeUs == Self.time(start))
            #expect(block.pcm.samples.first == Float(start))
            #expect(block.pcm.samples.last == -Float(start + Int64(Self.blockFrames) - 1))
        }
        #expect(assembler.nextSampleTime == 9_300)
    }

    @Test func fillsAShortGapWithSilence() {
        var assembler = Self.started()
        _ = assembler.take(Self.reply(start: 1_000, frames: Self.blockFrames), time: Self.time, now: Self.now)
        let output = assembler.take(Self.reply(start: 2_440, frames: Self.blockFrames), time: Self.time, now: Self.now)
        #expect(output.filledFrames == 480)
        let block = try! #require(output.blocks.first)
        #expect(block.captureTimeUs == Self.time(1_960))
        #expect(block.pcm.samples[0..<(480 * 2)].allSatisfy { $0 == 0 })
        #expect(block.pcm.samples[480 * 2] == 2_440)
    }

    @Test func continuesFromNowAfterAGapOfMoreThanASecond() {
        var assembler = Self.started()
        _ = assembler.take(Self.reply(start: 0, frames: 500), time: Self.time, now: Self.now)
        let later: Int64 = 500 + Int64(Self.rate) + 1
        let output = assembler.take(Self.reply(start: later, frames: Self.blockFrames), time: Self.time, now: Self.now)
        #expect(output.skippedFrames == Int64(Self.rate) + 1)
        #expect(output.blocks.count == 1)
        #expect(output.blocks.first?.captureTimeUs == Self.time(later))
        #expect(output.blocks.first?.pcm.samples.first == Float(later))
    }

    @Test func aRestartDropsPendingAudioAndTakesTheNewRate() {
        var assembler = Self.started()
        _ = assembler.take(Self.reply(start: 0, frames: 500), time: Self.time, now: Self.now)
        let restart = assembler.take(Self.reply(start: 0, frames: 100, session: 2, rate: 96_000),
                                     time: Self.time, now: Self.now)
        #expect(restart.timeline == .restarted)
        #expect(restart.blocks.isEmpty)
        #expect(assembler.nextSampleTime == -1)
        #expect(assembler.sampleRate == 96_000)
        #expect(assembler.blockFrames == 1_920)

        let output = assembler.take(Self.reply(start: 200, frames: 1_920, session: 2, rate: 96_000),
                                    time: Self.time, now: Self.now)
        let block = try! #require(output.blocks.first)
        #expect(block.pcm.sampleRate == 96_000)
        #expect(block.pcm.frameCount == 1_920)
        #expect(block.pcm.samples.first == 200)
    }

    @Test func holdsABlockUntilItsTimeIsKnown() {
        var assembler = Self.started()
        let held = assembler.take(Self.reply(start: 0, frames: Self.blockFrames), time: Self.noTime, now: Self.now)
        #expect(held.blocks.isEmpty)
        let output = assembler.take(Self.reply(start: Int64(Self.blockFrames), frames: Self.blockFrames),
                                    time: Self.time, now: Self.now)
        #expect(output.blocks.map(\.captureTimeUs) == [Self.time(0), Self.time(Int64(Self.blockFrames))])
        #expect(!output.usedCurrentTime)
    }

    @Test func onceHalfASecondWaitsItGoesByTheCurrentTimeLessItsAge() {
        var assembler = Self.started()
        let output = assembler.take(Self.reply(start: 0, frames: Self.rate / 2), time: Self.noTime, now: Self.now)
        #expect(output.usedCurrentTime)
        // All of it goes, contiguous, the oldest block half a second before now.
        #expect(output.blocks.count == 25)
        #expect(output.blocks.map(\.captureTimeUs) == (0..<25).map { Self.now() - 500_000 + Int64($0) * 20_000 })

        // Later blocks follow on until times are known again.
        let later = assembler.take(Self.reply(start: 24_000, frames: Self.blockFrames), time: Self.noTime, now: Self.now)
        #expect(later.blocks.map(\.captureTimeUs) == [Self.now() + 0])
        let known = assembler.take(Self.reply(start: 24_960, frames: Self.blockFrames), time: Self.time, now: Self.now)
        #expect(!known.usedCurrentTime)
        #expect(known.blocks.map(\.captureTimeUs) == [Self.time(24_960)])
    }

    @Test func aReplyFromBeforeTheLastOnesEndIsARestart() {
        var assembler = Self.started()
        _ = assembler.take(Self.reply(start: 100_000, frames: 1_500), time: Self.time, now: Self.now)
        // Same session, but the timeline went back (the driver bumps the session for this too).
        let output = assembler.take(Self.reply(start: 2_000, frames: 1_000), time: Self.time, now: Self.now)
        #expect(output.timeline == .restarted)
        #expect(output.blocks.isEmpty)
        #expect(assembler.nextSampleTime == -1)
        let after = assembler.take(Self.reply(start: 3_000, frames: Self.blockFrames), time: Self.time, now: Self.now)
        #expect(after.blocks.first?.captureTimeUs == Self.time(3_000))
        #expect(after.blocks.first?.pcm.samples.first == 3_000)
    }
}
