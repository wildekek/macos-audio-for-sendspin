import AudioToolbox
import CoreAudio
import Foundation
import SendspinServerKit

/// A block of captured audio with the server-clock time of its first sample.
public struct CapturedBlock: Sendable {
    public var pcm: PCMBuffer
    public var captureTimeUs: Int64

    public init(pcm: PCMBuffer, captureTimeUs: Int64) {
        self.pcm = pcm
        self.captureTimeUs = captureTimeUs
    }
}

/// Captures interleaved 32-bit float stereo from an input device with an AudioQueue.
///
/// It captures at the device's own sample rate by default (no conversion), and each
/// buffer carries the device's host-time stamp, which maps straight onto `ServerClock`.
public final class AudioCapture: @unchecked Sendable {
    public static let channels = 2

    public let deviceName: String
    public let sampleRate: Int
    public let blocks: AsyncStream<CapturedBlock>

    private var queue: AudioQueueRef?
    private let continuation: AsyncStream<CapturedBlock>.Continuation
    private let callbackQueue = DispatchQueue(label: "sendspin.capture", qos: .userInteractive)

    public convenience init(deviceName query: String, blockMs: Int = 20) throws {
        try self.init(device: AudioDevice.input(matching: query), blockMs: blockMs)
    }

    /// - Parameter sampleRate: capture rate; nil captures at the device's nominal rate.
    public init(device: AudioDevice, sampleRate: Int? = nil, blockMs: Int = 20) throws {
        guard let uid = device.uid else { throw AudioDeviceError.notFound("UID for device \(device.id)") }
        deviceName = device.name ?? uid
        let rate = sampleRate ?? Int(device.nominalSampleRate)
        self.sampleRate = rate
        (blocks, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(50))

        let bytesPerFrame = UInt32(MemoryLayout<Float>.size * Self.channels)
        var format = AudioStreamBasicDescription(
            mSampleRate: Float64(rate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 32,
            mReserved: 0)

        let continuation = continuation
        var newQueue: AudioQueueRef?
        try check("AudioQueueNewInput", AudioQueueNewInputWithDispatchQueue(
            &newQueue, &format, 0, callbackQueue
        ) { queue, buffer, startTime, _, _ in
            let bytes = Int(buffer.pointee.mAudioDataByteSize)
            if bytes > 0 {
                let samples = Array(UnsafeBufferPointer(
                    start: buffer.pointee.mAudioData.assumingMemoryBound(to: Float.self),
                    count: bytes / MemoryLayout<Float>.size))
                let hostTimeValid = startTime.pointee.mFlags.contains(.hostTimeValid)
                let captureTime = hostTimeValid
                    ? ServerClock.micros(fromHostTime: startTime.pointee.mHostTime)
                    : ServerClock.nowMicros()
                continuation.yield(CapturedBlock(
                    pcm: PCMBuffer(samples: samples, sampleRate: rate, channels: Self.channels),
                    captureTimeUs: captureTime))
            }
            AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
        })
        guard let newQueue else { throw AudioDeviceError.coreAudio("AudioQueueNewInput", -1) }
        queue = newQueue

        var deviceUID: CFString = uid as CFString
        try check("set CurrentDevice", withUnsafePointer(to: &deviceUID) {
            AudioQueueSetProperty(newQueue, kAudioQueueProperty_CurrentDevice, $0,
                                  UInt32(MemoryLayout<CFString>.size))
        })

        let bufferBytes = UInt32(rate * blockMs / 1000) * bytesPerFrame
        for _ in 0..<4 {
            var buffer: AudioQueueBufferRef?
            try check("AudioQueueAllocateBuffer", AudioQueueAllocateBuffer(newQueue, bufferBytes, &buffer))
            if let buffer { AudioQueueEnqueueBuffer(newQueue, buffer, 0, nil) }
        }
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard let queue else { return }
        try check("AudioQueueStart", AudioQueueStart(queue, nil))
    }

    public func stop() {
        guard let queue else { return }
        AudioQueueStop(queue, true)
        AudioQueueDispose(queue, true)
        self.queue = nil
        continuation.finish()
    }
}
