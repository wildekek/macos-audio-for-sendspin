import Foundation

/// Places a source's audio on the server clock (roles/source/v1.md, Source Audio Chunks). The
/// samples stay continuous and are timed by their count, from the first chunk's timestamp; the
/// chunks' own timestamps only anchor the stream, detect gaps and measure how far the input's
/// clock drifts from ours. Drift is absorbed one frame at a time, dropped or doubled with a short
/// crossfade, which keeps the input within half a millisecond of its timestamps.
///
/// Blocks come out timestamped `delayUs` after capture, as if the Mac had just captured them: a
/// chunk arrives up to 150 ms (its length) plus the network after its first sample.
struct InputTimeline {
    let sampleRate: Int
    let channels: Int

    static let delayUs: Int64 = 200_000
    /// A timestamp this far off the timeline is a new start (a gap, or the source restarted).
    static let resyncThresholdUs: Double = 100_000
    /// How far the smoothed drift may go before a frame is dropped or doubled.
    static let toleranceUs: Double = 500
    /// Frames over which a dropped or doubled frame is crossfaded.
    static let crossfadeFrames = 64

    private var anchorUs: Int64?
    private var framesOut: Int64 = 0
    /// Smoothed difference between the chunks' timestamps and the timeline, in µs: positive when
    /// the input runs slow, so frames must be added.
    private(set) var driftUs: Double = 0
    /// Frames doubled for a slow input clock, and dropped for a fast one.
    private(set) var doubled = 0
    private(set) var dropped = 0
    var corrections: Int { doubled + dropped }
    /// Starts over after a gap, the first chunk not counted.
    private(set) var resyncs = 0

    init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// The chunk's samples on the timeline, and the server-clock time to treat as their capture.
    mutating func place(_ samples: [Float], timestampUs: Int64) -> (samples: [Float], captureTimeUs: Int64) {
        let expected = anchorUs.map { $0 + framesOut * 1_000_000 / Int64(sampleRate) }
        guard let expected, abs(Double(timestampUs - expected)) < Self.resyncThresholdUs else {
            if anchorUs != nil { resyncs += 1 }
            anchorUs = timestampUs
            framesOut = Int64(samples.count / channels)
            driftUs = 0
            return (samples, timestampUs + Self.delayUs)
        }
        // About a second of smoothing over the time filter's own corrections.
        let chunkUs = Double(samples.count / channels) * 1_000_000 / Double(sampleRate)
        let weight = min(1, chunkUs / 1_000_000)
        driftUs += weight * (Double(timestampUs - expected) - driftUs)
        var out = samples
        let frames = samples.count / channels
        if frames > Self.crossfadeFrames + 1 {
            if driftUs > Self.toleranceUs {
                out = Self.doubleFrame(samples, channels: channels)
                driftUs -= 1_000_000 / Double(sampleRate)
                doubled += 1
            } else if driftUs < -Self.toleranceUs {
                out = Self.dropFrame(samples, channels: channels)
                driftUs += 1_000_000 / Double(sampleRate)
                dropped += 1
            }
        }
        framesOut += Int64(out.count / channels)
        return (out, expected + Self.delayUs)
    }

    /// One frame fewer: the start of the chunk fades into the same audio one frame on.
    static func dropFrame(_ samples: [Float], channels: Int) -> [Float] {
        let frames = samples.count / channels
        var out: [Float] = []
        out.reserveCapacity(samples.count - channels)
        for frame in 0..<frames - 1 {
            let w = min(1, Float(frame + 1) / Float(crossfadeFrames))
            for channel in 0..<channels {
                out.append((1 - w) * samples[frame * channels + channel] + w * samples[(frame + 1) * channels + channel])
            }
        }
        return out
    }

    /// One frame more: the chunk fades from in step into the same audio one frame behind.
    static func doubleFrame(_ samples: [Float], channels: Int) -> [Float] {
        let frames = samples.count / channels
        var out: [Float] = []
        out.reserveCapacity(samples.count + channels)
        for frame in 0...frames {
            let w = min(1, Float(frame) / Float(crossfadeFrames))
            for channel in 0..<channels {
                let current = samples[min(frame, frames - 1) * channels + channel]
                let behind = samples[max(frame - 1, 0) * channels + channel]
                out.append((1 - w) * current + w * behind)
            }
        }
        return out
    }
}
