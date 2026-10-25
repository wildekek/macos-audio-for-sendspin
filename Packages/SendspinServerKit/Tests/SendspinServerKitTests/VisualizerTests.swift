import Foundation
import Testing
@testable import SendspinServerKit

struct VisualizerTests {
    static let spectrum = VisualizerConfig.Spectrum(nDispBins: 32, scale: "log", fMin: 20, fMax: 20_000)

    /// A stereo sine at `hz`, in 10 ms blocks timestamped back to back from 1 s.
    static func sine(hz: Double, amplitude: Float = 1, seconds: Double = 1, rate: Int = 48_000)
        -> [(PCMBuffer, Int64)] {
        let block = rate / 100
        return (0..<Int(seconds * 100)).map { index in
            var samples: [Float] = []
            for frame in 0..<block {
                let t = Double(index * block + frame) / Double(rate)
                let value = amplitude * Float(sin(2 * .pi * hz * t))
                samples += [value, value]
            }
            return (PCMBuffer(samples: samples, sampleRate: rate, channels: 2), 1_000_000 + Int64(index) * 10_000)
        }
    }

    static func run(_ config: VisualizerConfig, _ blocks: [(PCMBuffer, Int64)]) -> [(timestampUs: Int64, message: Data)] {
        var analyzer = VisualizerAnalyzer(config: config, sampleRate: blocks[0].0.sampleRate, channels: 2)
        return blocks.flatMap { analyzer.process($0.0, timestampUs: $0.1) }
    }

    static func uint16(_ data: Data, at offset: Int) -> Int {
        Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1])
    }

    @Test func negotiatesASubsetItCanCompute() {
        let request = VisualizerConfig(types: ["beat", "spectrum", "loudness", "loudness", "pitch"], rateMax: 500,
                                       spectrum: Self.spectrum)
        #expect(request.negotiated() == VisualizerConfig(types: ["spectrum", "loudness"], rateMax: 120,
                                                         spectrum: Self.spectrum))
        // Too many bins, or a scale we don't know: no spectrum, rather than another one.
        var tooMany = Self.spectrum
        tooMany.nDispBins = 5000
        #expect(VisualizerConfig(types: ["spectrum", "peak"], rateMax: 30, spectrum: tooMany).negotiated()
            == VisualizerConfig(types: ["peak"], rateMax: 30, spectrum: nil))
        #expect(VisualizerConfig(types: ["spectrum"], rateMax: 30, spectrum: nil).isMalformed)
    }

    /// Frames come at the requested rate, each `[type][timestamp][data]`, in time order.
    @Test func periodicFramesFollowTheRate() throws {
        let frames = Self.run(VisualizerConfig(types: ["loudness"], rateMax: 30), Self.sine(hz: 1_000))
        #expect((28...30).contains(frames.count))
        let times = frames.map(\.timestampUs)
        #expect(times == times.sorted())
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 == 33_334 })
        let first = try #require(frames.first)
        #expect(first.message.count == 11)
        #expect(first.message.first == 16)
        let stamp = first.message.dropFirst().prefix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) }
        #expect(stamp == first.timestampUs)
    }

    /// A full-scale 1 kHz sine (A-weighting is 0 dB there) is close to full scale, and its
    /// f_peak lands on 1 kHz; a sine 40 dB down reads about two thirds lower.
    @Test func measuresASine() throws {
        let config = VisualizerConfig(types: ["loudness", "f_peak"], rateMax: 20)
        let loud = try #require(Self.run(config, Self.sine(hz: 1_000)).last { $0.message.first == 16 })
        let quiet = try #require(Self.run(config, Self.sine(hz: 1_000, amplitude: 0.01)).last { $0.message.first == 16 })
        let loudness = Self.uint16(loud.message, at: 9)
        #expect(loudness > 64_000)
        #expect(abs(Self.uint16(quiet.message, at: 9) - (loudness - 65_535 * 40 / 60)) < 1_500)

        let peak = try #require(Self.run(config, Self.sine(hz: 1_000)).last { $0.message.first == 18 })
        #expect(abs(Self.uint16(peak.message, at: 9) - 1_000) <= 3)
        #expect(Self.uint16(peak.message, at: 11) > 64_000)
    }

    @Test func theSpectrumPeaksInTheSinesBin() throws {
        let frame = try #require(Self.run(VisualizerConfig(types: ["spectrum"], rateMax: 20, spectrum: Self.spectrum),
                                          Self.sine(hz: 1_000)).last)
        #expect(frame.message.count == 9 + 2 * 32)
        let bins = (0..<32).map { Self.uint16(frame.message, at: 9 + 2 * $0) }
        let loudest = bins.indices.max { bins[$0] < bins[$1] }!
        // Log bins from 20 Hz to 20 kHz: 1 kHz is in bin 32 * log10(1000/20) / 3 ≈ 18.
        #expect(loudest == 18)
    }

    /// Silence, then a burst: one peak at the burst, none in the silence or the steady part.
    @Test func peaksMarkOnsets() {
        let silence = Self.sine(hz: 1_000, amplitude: 0, seconds: 0.5)
        let burst = Self.sine(hz: 1_000, seconds: 0.5).map { ($0.0, $0.1 + 500_000) }
        let peaks = Self.run(VisualizerConfig(types: ["peak"], rateMax: 1), silence + burst)
        #expect(peaks.count == 1)
        #expect((1_500_000...1_560_000).contains(peaks[0].timestampUs))
        #expect(peaks[0].message.count == 10)
    }

    /// A new analysis after a configuration change never goes back before the last frame.
    @Test func aNewAnalysisContinuesAfterTheLastFrame() throws {
        let blocks = Self.sine(hz: 440)
        var first = VisualizerAnalyzer(config: VisualizerConfig(types: ["loudness"], rateMax: 60), sampleRate: 48_000, channels: 2)
        let before = blocks.prefix(50).flatMap { first.process($0.0, timestampUs: $0.1) }
        var second = VisualizerAnalyzer(config: VisualizerConfig(types: ["loudness"], rateMax: 10), sampleRate: 48_000,
                                        channels: 2, after: first.lastUs)
        let after = blocks.dropFirst(50).flatMap { second.process($0.0, timestampUs: $0.1) }
        let last = try #require(before.last?.timestampUs)
        #expect(after.allSatisfy { $0.timestampUs >= last + 100_000 })
    }

    @Test func bufferCapacityCountsFutureFramesOnly() {
        var account = VisualizerBufferAccount()
        let first = account.admit(bytes: 60, timestampUs: 2_000, nowUs: 1_000, capacity: 100)
        let full = account.admit(bytes: 60, timestampUs: 3_000, nowUs: 1_000, capacity: 100)
        let firstShown = account.admit(bytes: 60, timestampUs: 3_000, nowUs: 2_000, capacity: 100)
        #expect(first && !full && firstShown)
    }
}
