/// `LocalPlayer`'s timing, apart from CoreAudio: stereo audio queued with the server-clock
/// time its frames are due, read out by an output so that each frame is heard at its time.
///
/// It follows the player role's suggested correction strategy (player/v1.md, Sample deletion
/// and insertion). In one shot at the start, after an underrun, and when the error passes
/// 1 ms: drop what's late, or wait in silence. Otherwise single frames are dropped or repeated
/// while the error is outside a 100 µs dead band, never more than 0.5% of the frames played.
/// The error is smoothed over about 200 ms first, since the output's timestamps jitter by
/// some tens of µs, and corrected at the start of a render.
///
/// Not thread-safe: the owner locks around it. Rendering allocates nothing.
final class PlayoutBuffer {
    static let channels = 2
    /// Errors within this are left alone.
    static let deadBandUs = 100.0
    /// Errors beyond this are put right in one shot.
    static let snapThresholdUs = 1_000.0
    /// How much of each new error measurement goes into the smoothed one, per render.
    static let smoothing = 0.05
    /// Written audio that continues from what's queued within this joins it.
    static let continuityUs = 1_000.0
    /// A gap up to this long between written blocks is filled with silence.
    static let maxGapUs = 1_000_000.0

    struct Counters: Equatable {
        /// One-shot corrections: at the start, after an underrun or a large error.
        var snaps = 0
        var droppedFrames = 0
        var repeatedFrames = 0
        var underruns = 0
        /// Writes that didn't fit.
        var overflows = 0
    }

    let sampleRate: Int
    let capacityFrames: Int
    var counters = Counters()
    private let ring: UnsafeMutablePointer<Float>
    private var readFrame = 0
    private(set) var queuedFrames = 0
    /// When the frame at `readFrame` is due; nil until audio is written after a reset.
    private var nextFrameUs: Double?
    private var needsSnap = true
    private(set) var smoothedErrorUs = 0.0
    private var framesSinceCorrection = 0

    /// Frames per soft correction: about 21 µs, whatever the rate.
    let correctionFrames: Int

    init(sampleRate: Int, capacitySeconds: Int = 4) {
        self.sampleRate = sampleRate
        capacityFrames = sampleRate * capacitySeconds
        ring = .allocate(capacity: capacityFrames * Self.channels)
        correctionFrames = max(1, Int((21 * Double(sampleRate) / 1_000_000).rounded()))
    }

    deinit {
        ring.deallocate()
    }

    private var frameUs: Double { 1_000_000 / Double(sampleRate) }

    /// Forget everything queued: the stream ended.
    func reset() {
        readFrame = 0
        queuedFrames = 0
        nextFrameUs = nil
        needsSnap = true
        smoothedErrorUs = 0
    }

    /// Queue interleaved stereo frames, the first due at `timestampUs`. Audio that continues
    /// what's queued joins it, a short gap is filled with silence, and anything else (a jump
    /// back, or a long gap) starts over from this audio.
    func write(_ samples: UnsafeBufferPointer<Float>, timestampUs: Int64) {
        let frames = samples.count / Self.channels
        let timeUs = Double(timestampUs)
        var gapFrames = 0
        if let nextFrameUs {
            let gapUs = timeUs - (nextFrameUs + Double(queuedFrames) * frameUs)
            if abs(gapUs) > Self.continuityUs {
                if gapUs > 0, gapUs <= Self.maxGapUs {
                    gapFrames = Int((gapUs / frameUs).rounded())
                } else {
                    reset()
                }
            }
        }
        guard queuedFrames + gapFrames + frames <= capacityFrames else {
            counters.overflows += 1
            return
        }
        if nextFrameUs == nil {
            nextFrameUs = timeUs
            needsSnap = true
        }
        append(silence: gapFrames)
        var source = 0
        while source < frames {
            let at = (readFrame + queuedFrames) % capacityFrames
            let count = min(frames - source, capacityFrames - at)
            (ring + at * Self.channels).update(from: samples.baseAddress! + source * Self.channels,
                                               count: count * Self.channels)
            queuedFrames += count
            source += count
        }
    }

    private func append(silence frames: Int) {
        var left = frames
        while left > 0 {
            let at = (readFrame + queuedFrames) % capacityFrames
            let count = min(left, capacityFrames - at)
            (ring + at * Self.channels).update(repeating: 0, count: count * Self.channels)
            queuedFrames += count
            left -= count
        }
    }

    /// Fill `frames` frames of interleaved stereo output, whose first frame is heard at
    /// `outputUs` on the server clock.
    func render(into output: UnsafeMutablePointer<Float>, frames: Int, outputUs: Double) {
        defer { framesSinceCorrection += frames }
        var written = 0
        if let nextFrameUs, queuedFrames > 0 {
            // Positive: the next frame was due before it can be heard.
            let errorUs = outputUs - nextFrameUs
            if !needsSnap {
                smoothedErrorUs += Self.smoothing * (errorUs - smoothedErrorUs)
                if abs(smoothedErrorUs) > Self.snapThresholdUs { needsSnap = true }
            }
            if needsSnap {
                if errorUs >= 0 {
                    drop(min(queuedFrames, Int((errorUs / frameUs).rounded())))
                } else {
                    written = min(frames, Int((-errorUs / frameUs).rounded()))
                    output.update(repeating: 0, count: written * Self.channels)
                }
                // Still nothing to play in time: try again with the next render.
                if queuedFrames > 0, written < frames {
                    needsSnap = false
                    smoothedErrorUs = 0
                    framesSinceCorrection = 0
                    counters.snaps += 1
                }
            } else if abs(smoothedErrorUs) > Self.deadBandUs,
                      framesSinceCorrection * 5 >= correctionFrames * 1_000 {
                // At most 0.5%: N frames per 200 N played.
                let step = min(correctionFrames, frames)
                if smoothedErrorUs > 0 {
                    drop(min(step, queuedFrames))
                    counters.droppedFrames += step
                    smoothedErrorUs -= Double(step) * frameUs
                } else {
                    for i in 0..<step {
                        (output + i * Self.channels).update(from: ring + readFrame * Self.channels,
                                                            count: Self.channels)
                    }
                    written = step
                    counters.repeatedFrames += step
                    smoothedErrorUs += Double(step) * frameUs
                }
                framesSinceCorrection = 0
            }
        }
        if !needsSnap {
            written += read(into: output + written * Self.channels, frames: frames - written)
            if written < frames, nextFrameUs != nil {
                counters.underruns += 1
                needsSnap = true
            }
        }
        (output + written * Self.channels).update(repeating: 0, count: (frames - written) * Self.channels)
    }

    private func drop(_ frames: Int) {
        readFrame = (readFrame + frames) % capacityFrames
        queuedFrames -= frames
        nextFrameUs? += Double(frames) * frameUs
    }

    private func read(into output: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        var done = 0
        while done < frames, queuedFrames > 0 {
            let count = min(frames - done, queuedFrames, capacityFrames - readFrame)
            (output + done * Self.channels).update(from: ring + readFrame * Self.channels,
                                                   count: count * Self.channels)
            drop(count)
            done += count
        }
        return done
    }
}
