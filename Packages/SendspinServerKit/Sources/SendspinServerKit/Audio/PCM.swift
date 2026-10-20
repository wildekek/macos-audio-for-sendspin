import Foundation

/// Interleaved 32-bit float PCM as captured: the internal format of the pipeline, at
/// whatever sample rate the Sendspin device runs. Players get it converted to their
/// own format by `PlayerAudioPipeline`.
public struct PCMBuffer: Sendable {
    public var samples: [Float]
    public var sampleRate: Int
    public var channels: Int

    public init(samples: [Float], sampleRate: Int, channels: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var frameCount: Int { samples.count / channels }

    public var durationUs: Int64 { Int64(frameCount) * 1_000_000 / Int64(sampleRate) }

    /// Whether every sample is exactly zero (the loopback produces digital silence
    /// when nothing plays).
    public var isSilent: Bool { samples.allSatisfy { $0 == 0 } }
}

/// Which of a player's formats to stream, given the source and the preferred bit depth.
public enum FormatChoice {
    /// PCM bit depths we can produce.
    public static let bitDepths = [16, 24, 32]

    /// The best format from `supported` for a source at `sourceRate`:
    /// - one whose audio for `bufferMs` fits the player's `bufferCapacity` (estimated: exact
    ///   for PCM, typical compression for FLAC), if any does;
    /// - the source rate if the player has it; otherwise a rate from the same family
    ///   (44.1 kHz multiples vs 48 kHz multiples, so 96 → 48 and 88.2 → 44.1), nearest
    ///   first; otherwise the nearest rate;
    /// - the preferred bit depth if available; otherwise a deeper one (no loss), then
    ///   the deepest shallower one;
    /// - the source's channel count if available;
    /// - then the player's own order: `supported_formats` lists its preference first.
    public static func best(from supported: [AudioFormatSpec], sourceRate: Int, sourceChannels: Int,
                            preferredBitDepth: Int, bufferCapacity: Int? = nil, bufferMs: Int = 0) -> AudioFormatSpec? {
        let candidates = supported.enumerated().filter { _, spec in
            let depths = spec.codec == AudioCodec.flac.rawValue ? FLACEncoder.bitDepths
                : spec.codec == AudioCodec.pcm.rawValue ? bitDepths : []
            return depths.contains(spec.bitDepth) && (1...2).contains(spec.channels)
        }
        func family(_ rate: Int) -> Int { rate % 11_025 == 0 ? 44_100 : 48_000 }
        func fits(_ spec: AudioFormatSpec) -> Bool {
            guard let bufferCapacity else { return true }
            let needed = estimatedBytesPerSecond(spec) * Double(bufferMs + chunkMs) / 1_000
            return needed <= Double(bufferCapacity)
        }
        func score(_ index: Int, _ spec: AudioFormatSpec) -> [Int] {
            let rateClass = spec.sampleRate == sourceRate ? 0 : family(spec.sampleRate) == family(sourceRate) ? 1 : 2
            let depthClass = spec.bitDepth == preferredBitDepth ? 0 : spec.bitDepth > preferredBitDepth ? 1 : 2
            return [fits(spec) ? 0 : 1, rateClass, abs(spec.sampleRate - sourceRate),
                    depthClass, abs(spec.bitDepth - preferredBitDepth),
                    spec.channels == sourceChannels ? 0 : 1, index]
        }
        return candidates.min { score($0.offset, $0.element).lexicographicallyPrecedes(score($1.offset, $1.element)) }?
            .element
    }

    /// Our chunks are 20 ms.
    static let chunkMs = 20

    /// Wire bytes per second, chunk headers included. FLAC at a typical 60% of PCM for music:
    /// only an estimate, the send-time accounting enforces the real limit.
    static func estimatedBytesPerSecond(_ spec: AudioFormatSpec) -> Double {
        let pcm = Double(spec.sampleRate * spec.channels * spec.bitDepth / 8)
        let headers = Double(AudioFrame.headerSize * 1_000 / chunkMs)
        return (spec.codec == AudioCodec.flac.rawValue ? pcm * 0.6 : pcm) + headers
    }
}
