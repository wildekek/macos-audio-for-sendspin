import AudioToolbox
import CoreAudio
import Foundation
import SendspinServerKit

/// Plays the group's audio on one of this Mac's own outputs, such as its speakers, in sync
/// with the Sendspin speakers: each frame is heard at its play time.
///
/// The server clock is host time, and so are CoreAudio's output timestamps, so there's no
/// clock to synchronize. What's left is the output's latency, which is added to each render
/// timestamp as apps add it for lip sync, and the drift of the output's own clock, which
/// `PlayoutBuffer` follows. The audio is converted to the output's rate when they differ.
///
/// The output runs only while the group plays. Its volume is the device's own (`volume`);
/// mute is applied here, so the device is left as the user set it.
public final class LocalPlayer: GroupOutput, @unchecked Sendable {
    public let device: AudioDevice

    private let queue = DispatchQueue(label: "sendspin.local-player", qos: .userInteractive)

    // Under `lock`: shared by `play`, `stop` and the render callback.
    private let lock = NSLock()
    private var playout: PlayoutBuffer
    private var latencyUs: Double
    private var muted = false
    private var wantsOutput = false

    // `play` and `stop` only: the group calls them one at a time.
    private var resampler: Resampler?
    private var resamplerSourceRate: Int?
    private var anchorUs: Int64?
    private var framesOut: Int64 = 0
    private var blocksPlayed = 0

    // Render thread only.
    private var gain: Float = 1

    // On `queue`.
    private var unit: AudioUnit?
    private var running = false
    private var rateObservation: PropertyObservation?

    public init(device: AudioDevice) {
        self.device = device
        let rate = Int(device.nominalSampleRate)
        playout = PlayoutBuffer(sampleRate: rate)
        latencyUs = Self.outputLatencyUs(device)
        rateObservation = device.observe(kAudioDevicePropertyNominalSampleRate, queue: queue) { [weak self] in
            self?.rateChanged()
        }
    }

    /// How long after its render timestamp a frame is heard: the stream's latency alone. The
    /// render timestamp already includes the device's latency and safety offset, by acoustic
    /// measurement: on a MacBook Pro's speakers (60 + 48 + 690 frames at 48 kHz), the full sum
    /// played 2.0 ms ahead of an AUX-2, and the stream latency alone matches what's heard.
    static func outputLatencyUs(_ device: AudioDevice) -> Double {
        Double(device.streamLatencyUs(scope: kAudioObjectPropertyScopeOutput))
    }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    /// The device's volume, 0…100; nil if it has none to set.
    public var volume: Int? {
        get { device.mainVolume.map { Int(($0 * 100).rounded()) } }
        set { device.mainVolume = newValue.map { Float32($0) / 100 } }
    }

    public var isMuted: Bool {
        get { lock.withLock { muted } }
        set { lock.withLock { muted = newValue } }
    }

    /// Stop for good, once the group no longer has it: the output is released.
    public func shutdown() {
        lock.withLock {
            playout.reset()
            wantsOutput = false
        }
        queue.sync {
            rateObservation = nil
            disposeUnit()
        }
    }

    // MARK: GroupOutput

    public func play(_ pcm: PCMBuffer, timestampUs: Int64) {
        let rate = lock.withLock { playout.sampleRate }
        var samples = Self.stereo(pcm.samples, channels: pcm.channels)
        if pcm.sampleRate != rate {
            if resampler == nil || resamplerSourceRate != pcm.sampleRate {
                resampler = Resampler(from: pcm.sampleRate, to: rate, channels: PlayoutBuffer.channels)
                resamplerSourceRate = pcm.sampleRate
                anchorUs = nil
            }
            guard let resampler else { return }
            samples = resampler.process(samples)
        } else if resampler != nil {
            resampler = nil
            anchorUs = nil
        }

        // Timestamps from a running frame count, as the resampler changes block lengths; a
        // jump in the group's timeline starts it again.
        let expectedUs = anchorUs.map { $0 + framesOut * 1_000_000 / Int64(rate) }
        if expectedUs.map({ abs($0 - timestampUs) > 10_000 }) ?? true {
            anchorUs = timestampUs
            framesOut = 0
            resampler?.reset()
        }
        let startUs = anchorUs! + framesOut * 1_000_000 / Int64(rate)
        framesOut += Int64(samples.count / PlayoutBuffer.channels)

        let (start, errorUs, counters) = lock.withLock {
            // The output changed rate meanwhile: this audio is at the old one.
            guard playout.sampleRate == rate else { return (false, 0.0, playout.counters) }
            samples.withUnsafeBufferPointer { playout.write($0, timestampUs: startUs) }
            let start = !wantsOutput
            wantsOutput = true
            return (start, playout.smoothedErrorUs, playout.counters)
        }
        if start { queue.async { self.applyRunning() } }
        blocksPlayed += 1
        if blocksPlayed.isMultiple(of: 500) {
            Log.debug("\(device.name ?? "This Mac"): " + String(format: "%+.0f µs off", errorUs)
                + ", \(counters.droppedFrames) frames dropped and \(counters.repeatedFrames) repeated, "
                + "\(counters.snaps) resyncs, \(counters.underruns) underruns")
        }
    }

    public func stop() {
        lock.withLock {
            playout.reset()
            wantsOutput = false
        }
        anchorUs = nil
        queue.async { self.applyRunning() }
    }

    // MARK: Output

    static func stereo(_ samples: [Float], channels: Int) -> [Float] {
        switch channels {
        case 2: return samples
        case 1: return samples.flatMap { [$0, $0] }
        default:
            let frames = samples.count / channels
            return (0..<frames).flatMap { [samples[$0 * channels], samples[$0 * channels + 1]] }
        }
    }

    /// Start or stop the output, as the group needs it.
    private func applyRunning() {
        let wanted = lock.withLock { wantsOutput }
        guard wanted != running else { return }
        if wanted {
            do {
                let unit = try unit ?? makeUnit()
                self.unit = unit
                try check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
                running = true
                Log.info("Playing on \(device.name ?? "this Mac") at \(Int(device.nominalSampleRate)) Hz, "
                    + String(format: "output latency %.1f ms", lock.withLock { latencyUs } / 1000))
            } catch {
                Log.error("Couldn't play on \(device.name ?? "this Mac"): \(error)")
                disposeUnit()
            }
        } else if let unit {
            AudioOutputUnitStop(unit)
            running = false
            let counters = lock.withLock {
                defer { playout.counters = PlayoutBuffer.Counters() }
                return playout.counters
            }
            Log.info("Stopped playing on \(device.name ?? "this Mac"): \(counters.snaps) resyncs, "
                + "\(counters.droppedFrames) frames dropped and \(counters.repeatedFrames) repeated for drift, "
                + "\(counters.underruns) underruns")
        }
    }

    /// The output changed sample rate (another app, or Audio MIDI Setup): what's queued is at
    /// the old rate and goes; the next audio is converted to the new one.
    private func rateChanged() {
        let rate = Int(device.nominalSampleRate)
        guard rate != lock.withLock({ playout.sampleRate }) else { return }
        Log.info("\(device.name ?? "This Mac") now runs at \(rate) Hz")
        disposeUnit()
        lock.withLock {
            playout = PlayoutBuffer(sampleRate: rate)
            latencyUs = Self.outputLatencyUs(device)
        }
        applyRunning()
    }

    private func disposeUnit() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        running = false
    }

    /// A HAL output unit on the device, taking interleaved stereo float at the device's own
    /// rate, so its render timestamps are the device's.
    private func makeUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioDeviceError.notFound("HAL output unit")
        }
        var newUnit: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &newUnit))
        guard let unit = newUnit else { throw AudioDeviceError.notFound("HAL output unit") }
        do {
            var deviceID = device.id
            try check("set output device", AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)))
            let channels = UInt32(PlayoutBuffer.channels)
            var format = AudioStreamBasicDescription(
                mSampleRate: Float64(lock.withLock { playout.sampleRate }), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
            try check("set stream format", AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
            var callback = AURenderCallbackStruct(
                inputProc: { refCon, _, timestamp, _, frameCount, ioData in
                    guard let ioData else { return noErr }
                    Unmanaged<LocalPlayer>.fromOpaque(refCon).takeUnretainedValue()
                        .render(ioData, frames: Int(frameCount), timestamp: timestamp.pointee)
                    return noErr
                },
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try check("set render callback", AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try check("AudioUnitInitialize", AudioUnitInitialize(unit))
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    /// On the render thread: the frames heard from the timestamp plus the output latency.
    private func render(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: Int, timestamp: AudioTimeStamp) {
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        guard let samples = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let target: Float
        if timestamp.mFlags.contains(.hostTimeValid) {
            let hostUs = Double(ServerClock.micros(fromHostTime: timestamp.mHostTime))
            target = lock.withLock {
                playout.render(into: samples, frames: frames, outputUs: hostUs + latencyUs)
                return muted ? 0 : 1
            }
        } else {
            samples.update(repeating: 0, count: frames * PlayoutBuffer.channels)
            target = gain
        }
        // Mute and unmute fade over one render, so they don't click.
        if gain != 1 || target != 1 {
            let step = (target - gain) / Float(max(1, frames))
            for frame in 0..<frames {
                let frameGain = gain + step * Float(frame + 1)
                samples[2 * frame] *= frameGain
                samples[2 * frame + 1] *= frameGain
            }
            gain = target
        }
    }
}
