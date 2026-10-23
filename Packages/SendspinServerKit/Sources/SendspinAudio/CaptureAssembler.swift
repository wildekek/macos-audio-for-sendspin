import SendspinServerKit

/// What the Sendspin driver returns for one read of its audio (property 'ssau').
struct DriverReply: Sendable {
    /// Sample time of the first frame.
    var start: Int64
    /// Changes whenever the device's timeline restarts (IO restart, rate change).
    var session: Int64
    /// The device's rate when it was read.
    var rate: Int
    /// Interleaved float32.
    var samples: [Float]
}

/// `DriverCapture`'s bookkeeping, apart from CoreAudio: turns the driver's replies into
/// fixed-size blocks with server-clock times, across gaps and timeline restarts.
///
/// A restart (a new `session`, or a reply from before where the last one ended) drops what's
/// pending and reads on from the newest frame, at the rate the device now runs. A gap of up to a second (a slow read) is filled with silence,
/// so the stream stays continuous; a longer one continues from now. A block whose time can't
/// be known yet (the device is restarting its IO) waits for the next reply, unless half a
/// second of audio waits: then the current time has to do, minus the age of that audio, and
/// the blocks after it follow on from there until times are known again.
struct CaptureAssembler {
    enum Timeline: Equatable {
        case started
        case restarted
    }

    struct Output {
        var blocks: [CapturedBlock] = []
        /// Set when the reply began a timeline: its audio is dropped, read again from the newest frame.
        var timeline: Timeline?
        var filledFrames: Int64 = 0
        var skippedFrames: Int64 = 0
        var usedCurrentTime = false
    }

    let channels: Int
    let blockMs: Int
    private(set) var sampleRate: Int
    private(set) var session: Int64?
    /// Where the next read starts; negative for the newest frame.
    private(set) var nextSampleTime: Int64 = -1
    private var pending: [Float] = []
    private var pendingStart: Int64 = 0
    /// Where the next block starts when times are being made up (see `emit`).
    private var fallbackTimeUs: Int64?

    init(sampleRate: Int, channels: Int, blockMs: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.blockMs = blockMs
    }

    var blockFrames: Int { sampleRate * blockMs / 1000 }

    /// - Parameters:
    ///   - time: a sample time's server-clock time (µs), or nil while it can't be known.
    ///   - now: the current server-clock time, for when it stays unknown.
    mutating func take(_ reply: DriverReply, time: (Int64) -> Int64?, now: () -> Int64) -> Output {
        var output = Output()
        // A reply from before the last one's end can only be a timeline that went back.
        let wentBack = nextSampleTime >= 0 && reply.start < nextSampleTime
        if reply.session != session || wentBack {
            output.timeline = session == nil ? .started : .restarted
            session = reply.session
            sampleRate = reply.rate
            nextSampleTime = -1
            pending = []
            fallbackTimeUs = nil
            return output
        }

        if nextSampleTime < 0 {
            pendingStart = reply.start
        } else if reply.start > nextSampleTime {
            let missing = reply.start - nextSampleTime
            if missing <= Int64(sampleRate) {
                pending += [Float](repeating: 0, count: Int(missing) * channels)
                output.filledFrames = missing
            } else {
                emit(into: &output, time: time, now: now)
                pending = []
                pendingStart = reply.start
                fallbackTimeUs = nil
                output.skippedFrames = missing
            }
        }
        pending += reply.samples
        nextSampleTime = reply.start + Int64(reply.samples.count / channels)
        emit(into: &output, time: time, now: now)
        return output
    }

    /// Hand out every whole block that's pending, while its time is known.
    private mutating func emit(into output: inout Output, time: (Int64) -> Int64?, now: () -> Int64) {
        let blockSamples = blockFrames * channels
        var offset = 0
        while pending.count - offset >= blockSamples {
            let knownTimeUs = time(pendingStart)
            var captureTimeUs = knownTimeUs
            if knownTimeUs == nil {
                if let fallback = fallbackTimeUs {
                    captureTimeUs = fallback
                } else if pending.count - offset >= sampleRate / 2 * channels {
                    // The oldest waiting frame was played about as long ago as the audio waiting.
                    let waitingUs = Int64((pending.count - offset) / channels) * 1_000_000 / Int64(sampleRate)
                    captureTimeUs = now() - waitingUs
                }
            }
            guard let captureTimeUs else { break }
            if knownTimeUs == nil {
                fallbackTimeUs = captureTimeUs + Int64(blockFrames) * 1_000_000 / Int64(sampleRate)
                output.usedCurrentTime = true
            } else {
                fallbackTimeUs = nil
            }
            output.blocks.append(CapturedBlock(
                pcm: PCMBuffer(samples: Array(pending[offset..<offset + blockSamples]),
                               sampleRate: sampleRate, channels: channels),
                captureTimeUs: captureTimeUs))
            offset += blockSamples
            pendingStart += Int64(blockFrames)
        }
        pending.removeFirst(offset)
    }
}
