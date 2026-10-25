import Foundation
import Testing
@testable import SendspinServerKit

struct FormatChoiceTests {
    static let aux2 = [
        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16),
        AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
        AudioFormatSpec(codec: .pcm, channels: 1, sampleRate: 48_000, bitDepth: 16),
    ]
    static let hiRes = [44_100, 48_000, 88_200, 96_000].flatMap { rate in
        [16, 24].map { AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: rate, bitDepth: $0) }
    }

    @Test func exactMatchWins() {
        let choice = FormatChoice.best(from: Self.hiRes, sourceRate: 96_000, sourceChannels: 2, preferredBitDepth: 24)
        #expect(choice == AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 96_000, bitDepth: 24))
    }

    @Test func fallsBackWithinRateFamily() {
        let at176 = FormatChoice.best(from: Self.hiRes, sourceRate: 176_400, sourceChannels: 2, preferredBitDepth: 24)
        #expect(at176?.sampleRate == 88_200)  // 44.1 kHz family, nearest
        let at192 = FormatChoice.best(from: Self.hiRes, sourceRate: 192_000, sourceChannels: 2, preferredBitDepth: 24)
        #expect(at192?.sampleRate == 96_000)
    }

    /// The AUX-2 lists FLAC first: with PCM at the same rate and depth, its order decides.
    @Test func aux2GetsItsPreferredFLAC() {
        let choice = FormatChoice.best(from: Self.aux2, sourceRate: 96_000, sourceChannels: 2, preferredBitDepth: 24)
        #expect(choice == AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16))
    }

    @Test func prefersDeeperOverShallowerBitDepth() {
        let formats = [16, 32].map { AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: $0) }
        let choice = FormatChoice.best(from: formats, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 24)
        #expect(choice?.bitDepth == 32)
    }

    @Test func servesFLACOnlyButNotOpusOnly() {
        let flacOnly = [AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16)]
        #expect(FormatChoice.best(from: flacOnly, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 16)?.codec
            == "flac")
        let opusOnly = [AudioFormatSpec(codec: .opus, channels: 2, sampleRate: 48_000, bitDepth: 16)]
        #expect(FormatChoice.best(from: opusOnly, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 16) == nil)
    }

    /// PCM at 48 kHz/16-bit stereo is ~192 kB/s: 500 ms of it doesn't fit in 80 kB, FLAC does.
    @Test func picksAFormatThatFitsTheBufferCapacity() {
        let pcmFirst = [AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16),
                        AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16)]
        let unlimited = FormatChoice.best(from: pcmFirst, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 16)
        #expect(unlimited?.codec == "pcm")
        let small = FormatChoice.best(from: pcmFirst, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 16,
                                      bufferCapacity: 80_000, bufferMs: 500)
        #expect(small?.codec == "flac")
    }

    /// FLAC carries 16 or 24 bits; a 32-bit FLAC entry isn't one we can produce.
    @Test func skipsFLACAt32Bit() {
        let formats = [AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 32),
                       AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 32)]
        #expect(FormatChoice.best(from: formats, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 32)?.codec
            == "pcm")
    }
}

struct PlayerAudioPipelineTests {
    private func pcm(_ samples: [Float], rate: Int = 48_000, channels: Int = 2) -> PCMBuffer {
        PCMBuffer(samples: samples, sampleRate: rate, channels: channels)
    }

    /// Padded with silence to the shortest chunk that goes out at once (15 ms at 48 kHz mono).
    private func padded(_ samples: [Float]) -> [Float] {
        samples + [Float](repeating: 0, count: max(0, 720 - samples.count))
    }

    private func format(rate: Int = 48_000, depth: Int, channels: Int = 2) -> AudioFormatSpec {
        AudioFormatSpec(codec: .pcm, channels: channels, sampleRate: rate, bitDepth: depth)
    }

    @Test func packs24BitLittleEndianIn3Bytes() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 24, channels: 1),
                                                        sourceRate: 48_000, sourceChannels: 1))
        let outResult = pipeline.process(pcm(padded([0.5, -1.0]), channels: 1), timestampUs: 1_000)
        let out = try #require(outResult.first)
        // 0.5 → 0x400000, −1.0 → 0x800000 (full-scale negative)
        #expect(Array(out.payload.prefix(6)) == [0x00, 0x00, 0x40, 0x00, 0x00, 0x80])
        #expect(out.timestampUs == 1_000)
    }

    @Test func clips16BitAtFullScale() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16, channels: 1),
                                                        sourceRate: 48_000, sourceChannels: 1))
        let outResult = pipeline.process(pcm(padded([2.0, -2.0]), channels: 1), timestampUs: 0)
        let out = try #require(outResult.first)
        let values = out.payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(values.prefix(2) == [Int16.max, Int16.min])
    }

    /// 2³¹ − 1 isn't a Float: full scale at 32-bit must clip, not trap.
    @Test func clips32BitAtFullScale() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 32, channels: 1),
                                                        sourceRate: 48_000, sourceChannels: 1))
        let outResult = pipeline.process(pcm(padded([1.0, 2.0, -2.0]), channels: 1), timestampUs: 0)
        let out = try #require(outResult.first)
        let values = out.payload.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        #expect(values.prefix(3) == [Int32.max, Int32.max, Int32.min])
    }

    /// 16-bit values and silence pass untouched; only finer samples get dither.
    @Test func dithersOnlySamplesFinerThan16Bit() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16, channels: 1),
                                                        sourceRate: 48_000, sourceChannels: 1))
        let sixteenBit: [Int16] = (0..<1_000).map { Int16(truncatingIfNeeded: $0 &* 7_919) }
        let input = sixteenBit.map { Float($0) / 32_768 } + [Float](repeating: 0, count: 1_000)
        let out = try #require(pipeline.process(pcm(input, channels: 1), timestampUs: 0).first)
        let values = out.payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(values == sixteenBit + [Int16](repeating: 0, count: 1_000))

        // Halfway between two 16-bit values: dither spreads them over both neighbours.
        let finer = [Float](repeating: 100.5 / 32_768, count: 1_000)
        let dithered = try #require(pipeline.process(pcm(finer, channels: 1), timestampUs: 41_667).first)
        let ditheredValues = dithered.payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(Set(ditheredValues).isSuperset(of: [100, 101]))
    }

    @Test func downmixesStereoToMono() {
        #expect(PlayerAudioPipeline.mix([0.25, 0.75, -0.5, 0.5], from: 2, to: 1) == [0.5, 0])
        #expect(PlayerAudioPipeline.mix([0.1, 0.2], from: 1, to: 2) == [0.1, 0.1, 0.2, 0.2])
    }

    @Test func resampledTimelineIsContiguous() throws {
        // 96 kHz source → 48 kHz player, 20 ms chunks, input timestamps with ±1 ms jitter.
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16),
                                                        sourceRate: 96_000, sourceChannels: 2))
        let chunk = pcm([Float](repeating: 0.1, count: 1_920 * 2), rate: 96_000)
        var expectedNext: Int64?
        var totalFrames = 0
        for i in 0..<50 {
            let jitter: Int64 = i.isMultiple(of: 2) ? 1_000 : -1_000
            guard let out = pipeline.process(chunk, timestampUs: 1_000_000 + Int64(i) * 20_000 + jitter).first else { continue }
            let frames = out.payload.count / 4  // 16-bit stereo
            if let expectedNext { #expect(out.timestampUs == expectedNext) }
            expectedNext = out.timestampUs + Int64(frames) * 1_000_000 / 48_000
            totalFrames += frames
        }
        // 1 s of input → ~1 s at 48 kHz (the resampler may hold back a few frames).
        #expect(abs(totalFrames - 48_000) < 64)
    }

    /// A source's blocks can be any length: PCM goes out in chunks of 15 to 150 ms, contiguous.
    @Test func pcmChunksStayBetween15And150Milliseconds() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16), sourceRate: 48_000, sourceChannels: 2))
        var chunks: [PlayerAudioPipeline.Chunk] = []
        var inputUs: Int64 = 0
        // 10 ms blocks, then one of 150 ms and a frame, then 5 ms blocks.
        for frames in [Int](repeating: 480, count: 6) + [7_201] + [Int](repeating: 240, count: 12) {
            chunks += pipeline.process(pcm([Float](repeating: 0.1, count: frames * 2)), timestampUs: inputUs)
            inputUs += Int64(frames) * 1_000_000 / 48_000
        }
        #expect(chunks.allSatisfy { (720...7_200).contains($0.frames) })
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            #expect(next.timestampUs == previous.timestampUs + Int64(previous.frames) * 1_000_000 / 48_000)
        }
        // What's not out yet is less than one shortest chunk.
        let total = 6 * 480 + 7_201 + 12 * 240
        #expect(total - chunks.reduce(0) { $0 + $1.frames } < 720)
    }

    /// Flushed, a FLAC stream gives up every frame it holds, the last one shorter, and ends
    /// where its input ends: a new format can start right there (player/v1.md, stream/start).
    @Test func flacFlushEndsWhereTheInputEnds() throws {
        var pipeline = try #require(PlayerAudioPipeline(
            format: AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16),
            sourceRate: 48_000, sourceChannels: 2))
        let block = pcm([Float](repeating: 0.1, count: 480 * 2))  // 10 ms
        var chunks: [PlayerAudioPipeline.Chunk] = []
        for i in 0..<7 { chunks += pipeline.process(block, timestampUs: Int64(i) * 10_000) }  // 70 ms: 3.5 frames
        chunks += pipeline.flush()
        #expect(chunks.reduce(0) { $0 + $1.frames } == 7 * 480)
        #expect(chunks.last?.frames == 480)
        #expect(pipeline.endUs == 70_000)
    }

    /// A format change mid-stream: the old pipeline's tail, the resampler's included, goes out
    /// first, and the new format starts exactly where it ends.
    @Test func aNewFormatContinuesTheOld() throws {
        var old = try #require(PlayerAudioPipeline(format: format(rate: 44_100, depth: 16), sourceRate: 48_000,
                                                   sourceChannels: 2))
        let block = pcm([Float](repeating: 0.1, count: 960 * 2))
        var sent = 0
        for i in 0..<10 { sent += old.process(block, timestampUs: Int64(i) * 20_000).reduce(0) { $0 + $1.frames } }
        sent += old.flush().reduce(0) { $0 + $1.frames }
        // 200 ms at 44.1 kHz, the filter's tail included.
        #expect(abs(sent - 8_820) <= 2)
        let endUs = try #require(old.endUs)
        var new = try #require(PlayerAudioPipeline(format: format(depth: 16), sourceRate: 48_000, sourceChannels: 2,
                                                   continuingAt: endUs))
        let first = try #require(new.process(block, timestampUs: 200_000).first)
        #expect(first.timestampUs == endUs)
        #expect(abs(endUs - 200_000) < 100)
    }

    /// Never before audio already out, even when the input's timeline went back.
    @Test func neverStartsBeforeWhatWasSent() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16), sourceRate: 48_000, sourceChannels: 2,
                                                        continuingAt: 1_000_000))
        let block = pcm([Float](repeating: 0.1, count: 960 * 2))
        let first = try #require(pipeline.process(block, timestampUs: 950_000).first)
        #expect(first.timestampUs == 1_000_000)
        // The input runs on from 950 ms without restarting: the next chunk follows the first.
        let second = try #require(pipeline.process(block, timestampUs: 970_000).first)
        #expect(second.timestampUs == 1_020_000)
    }

    @Test func resyncsAfterAGap() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16), sourceRate: 48_000, sourceChannels: 2))
        let chunk = pcm([Float](repeating: 0, count: 960 * 2))
        let firstResult = pipeline.process(chunk, timestampUs: 0)
        let first = try #require(firstResult.first)
        let secondResult = pipeline.process(chunk, timestampUs: 20_000)
        let second = try #require(secondResult.first)
        let afterGapResult = pipeline.process(chunk, timestampUs: 500_000)
        let afterGap = try #require(afterGapResult.first)
        #expect(first.timestampUs == 0)
        #expect(second.timestampUs == 20_000)
        #expect(afterGap.timestampUs == 500_000)
    }

    /// FLAC: one 20 ms frame per 20 ms of input (one held in the encoder), timestamped by
    /// frame count so they're contiguous, and the timeline restarts after a gap.
    @Test func flacFramesAreContiguousAndRestartAfterAGap() throws {
        let flac = AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16)
        var pipeline = try #require(PlayerAudioPipeline(format: flac, sourceRate: 48_000, sourceChannels: 2))
        #expect(pipeline.codecHeader?.prefix(4) == Data("fLaC".utf8))
        let chunk = pcm((0..<960 * 2).map { Float(sin(Double($0) / 7)) * 0.3 })
        var timestamps: [Int64] = []
        for i in 0..<10 {
            for out in pipeline.process(chunk, timestampUs: Int64(i) * 20_000) {
                #expect(out.frames == 960)
                #expect(out.payload.prefix(2) == Data([0xFF, 0xF8]))
                timestamps.append(out.timestampUs)
            }
        }
        #expect(timestamps == (0..<9).map { Int64($0) * 20_000 })

        // After a gap the old held block is dropped, not stamped on the new timeline.
        var afterGap: [Int64] = []
        for i in 0..<3 {
            afterGap += pipeline.process(chunk, timestampUs: 1_000_000 + Int64(i) * 20_000).map(\.timestampUs)
        }
        #expect(afterGap == [1_000_000, 1_020_000])
    }
}
