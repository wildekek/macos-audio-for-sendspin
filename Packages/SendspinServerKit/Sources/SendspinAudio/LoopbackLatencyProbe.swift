import AudioToolbox
import CoreAudio
import Foundation
import SendspinServerKit

/// Measures how the capture timestamps relate to the output timestamps apps see.
///
/// An app writing a sample into the device is told (via its render timestamp) at which
/// host time that sample is "played". The bridge schedules the sample on the players at
/// its *capture* timestamp plus the lead. So the latency to report for A/V sync is
/// `lead + (captureTime − outputTime)`, and this probe measures that difference: it plays
/// single-sample clicks through an AUHAL output unit, records each click's output host
/// time, and finds the clicks again in `AudioCapture`'s stream.
public enum LoopbackLatencyProbe {
    public struct Result: Sendable {
        /// captureTime − outputTime per detected click, µs.
        public var offsetsUs: [Int64]
        public var clicksPlayed: Int

        public var medianUs: Int64? {
            guard !offsetsUs.isEmpty else { return nil }
            return offsetsUs.sorted()[offsetsUs.count / 2]
        }
    }

    public static func measure(device: AudioDevice, clicks: Int = 10,
                               interval: Duration = .milliseconds(300)) async throws -> Result {
        let capture = try AudioCapture(device: device, sampleRate: 48_000, blockMs: 10)
        let detector = Task {
            var detected: [Int64] = []
            for await block in capture.blocks {
                let samples = block.pcm.samples
                for frame in 0..<block.pcm.frameCount where samples[frame * block.pcm.channels] > 0.5 {
                    detected.append(block.captureTimeUs
                        + Int64(frame) * 1_000_000 / Int64(block.pcm.sampleRate))
                }
            }
            return detected
        }
        try capture.start()

        let player = try SignalPlayer(device: device, signal: [0.9],
                                      intervalFrames: Int(interval / .milliseconds(1)) * 48)
        try await Task.sleep(for: .milliseconds(200)) // let capture settle before the first click
        try player.start()
        try await Task.sleep(for: interval * Double(clicks) + .milliseconds(150))
        player.stop()
        try await Task.sleep(for: .milliseconds(300)) // the last click still has to be captured
        capture.stop()

        let played = player.startTimesUs
        let detected = await detector.value
        // Pair each detected click with the nearest played one.
        let offsets = detected.compactMap { captured -> Int64? in
            guard let nearest = played.min(by: { abs(captured - $0) < abs(captured - $1) }) else { return nil }
            let offset = captured - nearest
            return abs(offset) < Int64(interval / .microseconds(1)) / 2 ? offset : nil
        }
        return Result(offsetsUs: offsets, clicksPlayed: played.count)
    }
}

/// Plays `signal` (48 kHz mono, sent to both channels) every `intervalFrames` into a
/// device and records the output host time (µs) at which each repetition starts, as
/// reported in the render timestamps.
final class SignalPlayer: @unchecked Sendable {
    private var unit: AudioUnit?
    private let state: State

    final class State: @unchecked Sendable {
        let signal: [Float32]
        let intervalFrames: Int
        var frame = 0
        let lock = NSLock()
        var startTimes: [Int64] = []

        init(signal: [Float32], intervalFrames: Int) {
            self.signal = signal
            self.intervalFrames = intervalFrames
        }
    }

    var startTimesUs: [Int64] { state.lock.withLock { state.startTimes } }

    init(device: AudioDevice, signal: [Float32], intervalFrames: Int) throws {
        precondition(signal.count < intervalFrames, "signal must fit in the interval")
        state = State(signal: signal, intervalFrames: intervalFrames)
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioDeviceError.notFound("HAL output unit")
        }
        var newUnit: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &newUnit))
        guard let newUnit else { throw AudioDeviceError.notFound("HAL output unit") }
        unit = newUnit

        var deviceID = device.id
        try check("set output device", AudioUnitSetProperty(
            newUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)))

        var format = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try check("set stream format", AudioUnitSetProperty(
            newUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, _, timestamp, _, frameCount, ioData in
                let state = Unmanaged<State>.fromOpaque(refCon).takeUnretainedValue()
                guard let ioData else { return noErr }
                let buffers = UnsafeMutableAudioBufferListPointer(ioData)
                guard let samples = buffers[0].mData?.assumingMemoryBound(to: Float32.self) else { return noErr }
                let hostUs = ServerClock.micros(fromHostTime: timestamp.pointee.mHostTime)
                for i in 0..<Int(frameCount) {
                    let position = state.frame % state.intervalFrames
                    let value = position < state.signal.count ? state.signal[position] : 0
                    samples[2 * i] = value
                    samples[2 * i + 1] = value
                    if position == 0 {
                        state.lock.withLock {
                            state.startTimes.append(hostUs + Int64(i) * 1_000_000 / 48_000)
                        }
                    }
                    state.frame += 1
                }
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(state).toOpaque())
        try check("set render callback", AudioUnitSetProperty(
            newUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try check("AudioUnitInitialize", AudioUnitInitialize(newUnit))
    }

    func start() throws {
        guard let unit else { return }
        try check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
    }

    func stop() {
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
    }

    deinit {
        stop()
    }
}
