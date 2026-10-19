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

    @Test func legacyPlayerGetsWhatItSupports() {
        let choice = FormatChoice.best(from: Self.aux2, sourceRate: 96_000, sourceChannels: 2, preferredBitDepth: 24)
        #expect(choice == AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: 16))
    }

    @Test func prefersDeeperOverShallowerBitDepth() {
        let formats = [16, 32].map { AudioFormatSpec(codec: .pcm, channels: 2, sampleRate: 48_000, bitDepth: $0) }
        let choice = FormatChoice.best(from: formats, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 24)
        #expect(choice?.bitDepth == 32)
    }

    @Test func ignoresNonPCM() {
        let flacOnly = [AudioFormatSpec(codec: .flac, channels: 2, sampleRate: 48_000, bitDepth: 16)]
        #expect(FormatChoice.best(from: flacOnly, sourceRate: 48_000, sourceChannels: 2, preferredBitDepth: 16) == nil)
    }
}

struct PlayerAudioPipelineTests {
    private func pcm(_ samples: [Float], rate: Int = 48_000, channels: Int = 2) -> PCMBuffer {
        PCMBuffer(samples: samples, sampleRate: rate, channels: channels)
    }

    private func format(rate: Int = 48_000, depth: Int, channels: Int = 2) -> AudioFormatSpec {
        AudioFormatSpec(codec: .pcm, channels: channels, sampleRate: rate, bitDepth: depth)
    }

    @Test func packs24BitLittleEndianIn3Bytes() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 24, channels: 1),
                                                        sourceRate: 48_000, sourceChannels: 1))
        let outResult = pipeline.process(pcm([0.5, -1.0], channels: 1), timestampUs: 1_000)
        let out = try #require(outResult)
        // 0.5 → 0x400000, −1.0 → 0x800000 (full-scale negative)
        #expect(Array(out.payload) == [0x00, 0x00, 0x40, 0x00, 0x00, 0x80])
        #expect(out.timestampUs == 1_000)
    }

    @Test func clips16BitAtFullScale() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16, channels: 1),
                                                        sourceRate: 48_000, sourceChannels: 1))
        let outResult = pipeline.process(pcm([2.0, -2.0], channels: 1), timestampUs: 0)
        let out = try #require(outResult)
        let values = out.payload.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(values == [Int16.max, Int16.min])
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
            guard let out = pipeline.process(chunk, timestampUs: 1_000_000 + Int64(i) * 20_000 + jitter) else { continue }
            let frames = out.payload.count / 4  // 16-bit stereo
            if let expectedNext { #expect(out.timestampUs == expectedNext) }
            expectedNext = out.timestampUs + Int64(frames) * 1_000_000 / 48_000
            totalFrames += frames
        }
        // 1 s of input → ~1 s at 48 kHz (the resampler may hold back a few frames).
        #expect(abs(totalFrames - 48_000) < 64)
    }

    @Test func resyncsAfterAGap() throws {
        var pipeline = try #require(PlayerAudioPipeline(format: format(depth: 16), sourceRate: 48_000, sourceChannels: 2))
        let chunk = pcm([Float](repeating: 0, count: 960 * 2))
        let firstResult = pipeline.process(chunk, timestampUs: 0)
        let first = try #require(firstResult)
        let secondResult = pipeline.process(chunk, timestampUs: 20_000)
        let second = try #require(secondResult)
        let afterGapResult = pipeline.process(chunk, timestampUs: 500_000)
        let afterGap = try #require(afterGapResult)
        #expect(first.timestampUs == 0)
        #expect(second.timestampUs == 20_000)
        #expect(afterGap.timestampUs == 500_000)
    }
}
