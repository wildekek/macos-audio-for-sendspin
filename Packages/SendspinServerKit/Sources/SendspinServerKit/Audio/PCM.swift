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

    /// The best PCM format from `supported` for a source at `sourceRate`:
    /// - the source rate if the player has it; otherwise a rate from the same family
    ///   (44.1 kHz multiples vs 48 kHz multiples, so 96 → 48 and 88.2 → 44.1), nearest
    ///   first; otherwise the nearest rate;
    /// - the preferred bit depth if available; otherwise a deeper one (no loss), then
    ///   the deepest shallower one;
    /// - the source's channel count if available.
    public static func best(from supported: [AudioFormatSpec], sourceRate: Int, sourceChannels: Int,
                            preferredBitDepth: Int) -> AudioFormatSpec? {
        let candidates = supported.filter {
            $0.codec == AudioCodec.pcm.rawValue && bitDepths.contains($0.bitDepth) && (1...2).contains($0.channels)
        }
        func family(_ rate: Int) -> Int { rate % 11_025 == 0 ? 44_100 : 48_000 }
        func score(_ spec: AudioFormatSpec) -> [Int] {
            let rateClass = spec.sampleRate == sourceRate ? 0 : family(spec.sampleRate) == family(sourceRate) ? 1 : 2
            let depthClass = spec.bitDepth == preferredBitDepth ? 0 : spec.bitDepth > preferredBitDepth ? 1 : 2
            return [rateClass, abs(spec.sampleRate - sourceRate),
                    depthClass, abs(spec.bitDepth - preferredBitDepth),
                    spec.channels == sourceChannels ? 0 : 1]
        }
        return candidates.min { score($0).lexicographicallyPrecedes(score($1)) }
    }
}
