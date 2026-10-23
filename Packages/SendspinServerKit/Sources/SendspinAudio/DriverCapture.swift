import CoreAudio
import Foundation
import SendspinServerKit

/// Reads the audio played to the Sendspin device straight from its driver (device property
/// 'ssau'), in blocks with the server-clock time of their first sample.
///
/// Unlike recording an input, this needs no microphone permission: the device is a speaker,
/// and the driver only hands its audio to this app and sendspin-bridge. A silent output
/// callback keeps the device running, so the timeline (and the silence) goes on while
/// nothing plays. Each block's time is its device sample time translated to host time, the
/// same line the output render timestamps of apps playing into the device sit on.
///
/// When the device changes sample rate, capture carries on at the new rate: each block
/// carries its own. When reads keep failing (the device went away, e.g. coreaudiod restarted
/// and the device is back under another object ID), capture ends by itself: `blocks`
/// finishes, so the owner can start again. The bookkeeping is `CaptureAssembler`'s.
public final class DriverCapture: @unchecked Sendable {
    public static let channels = 2
    /// Custom driver property 'ssau': audio from a sample time on.
    static let audioSelector: AudioObjectPropertySelector = 0x7373_6175
    /// The most frames the driver returns per read.
    static let maxReadFrames = 1 << 15
    /// Failed reads in a row (half a second) after which capture ends.
    static let maxFailedReads = 50

    public let deviceName: String
    /// The device's rate when capture started; blocks carry the rate they're at.
    public let sampleRate: Int
    public let blocks: AsyncStream<CapturedBlock>

    private let device: AudioDevice
    private let continuation: AsyncStream<CapturedBlock>.Continuation
    private let queue = DispatchQueue(label: "sendspin.capture", qos: .userInteractive)
    // Set by start, taken by stop, which runs on the owner's thread or, when capture ends by
    // itself, on `queue`.
    private let lock = NSLock()
    private var ioProc: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?

    // On `queue`.
    private var assembler: CaptureAssembler
    private var timelineRestarts = 0
    private var failedReads = 0
    private var usingCurrentTime = false

    public init(device: AudioDevice, blockMs: Int = 20) throws {
        var address = AudioDevice.globalAddress(Self.audioSelector)
        guard AudioObjectHasProperty(device.id, &address) else { throw AudioDeviceError.driverTooOld }
        self.device = device
        deviceName = device.name ?? AudioDevice.sendspinUID
        sampleRate = Int(device.nominalSampleRate)
        assembler = CaptureAssembler(sampleRate: sampleRate, channels: Self.channels, blockMs: blockMs)
        (blocks, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(50))
    }

    deinit {
        stop()
    }

    /// How often the device's timeline restarted since capture started (each rate change,
    /// and each configuration change of the device, restarts it once).
    public var timelineRestartCount: Int { queue.sync { timelineRestarts } }

    public func start() throws {
        guard lock.withLock({ ioProc == nil }) else { return }
        // Fails here, not silently later, when the driver won't hand this process its audio.
        _ = try read(from: -1)

        var newProc: AudioDeviceIOProcID?
        try check("AudioDeviceCreateIOProcID", AudioDeviceCreateIOProcIDWithBlock(&newProc, device.id, nil) {
            _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        })
        guard let newProc else { throw AudioDeviceError.coreAudio("AudioDeviceCreateIOProcID", -1) }
        lock.withLock { ioProc = newProc }
        try check("AudioDeviceStart", AudioDeviceStart(device.id, newProc))

        // A menu bar app is otherwise a candidate for App Nap, which would slow the reads.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Streaming audio")
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.poll() }
        lock.withLock {
            self.activity = activity
            self.timer = timer
        }
        timer.resume()
    }

    public func stop() {
        let (timer, ioProc, activity) = lock.withLock {
            defer {
                self.timer = nil
                self.ioProc = nil
                self.activity = nil
            }
            return (self.timer, self.ioProc, self.activity)
        }
        timer?.cancel()
        if let ioProc {
            AudioDeviceStop(device.id, ioProc)
            AudioDeviceDestroyIOProcID(device.id, ioProc)
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        continuation.finish()
    }

    // MARK: Reading

    private func read(from sampleTime: Int64) throws -> DriverReply {
        var address = AudioDevice.globalAddress(Self.audioSelector)
        var qualifier: CFPropertyList = NSNumber(value: sampleTime)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(device.id, &address, UInt32(MemoryLayout<CFPropertyList>.size), $0,
                                       &size, &value)
        }
        if status == kAudioHardwareIllegalOperationError { throw AudioDeviceError.driverRefused }
        try check("read Sendspin audio", status)
        guard let reply = value?.takeRetainedValue() as? [String: Any],
              let start = (reply["start"] as? NSNumber)?.int64Value,
              let session = (reply["session"] as? NSNumber)?.int64Value,
              let rate = (reply["rate"] as? NSNumber)?.intValue,
              let frames = reply["frames"] as? Data
        else { throw AudioDeviceError.coreAudio("read Sendspin audio", -1) }
        let samples = frames.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return DriverReply(start: start, session: session, rate: rate, samples: samples)
    }

    private func poll() {
        while true {
            let reply: DriverReply
            do {
                reply = try read(from: assembler.nextSampleTime)
            } catch {
                if failedReads == 0 { Log.error("Reading the Sendspin audio failed: \(error)") }
                failedReads += 1
                if failedReads == Self.maxFailedReads {
                    Log.error("Reading the Sendspin audio keeps failing; capture ends")
                    stop()
                }
                return
            }
            failedReads = 0
            let output = assembler.take(reply, time: captureTime(of:), now: ServerClock.nowMicros)
            if output.timeline == .restarted {
                timelineRestarts += 1
                Log.info("Sendspin device timeline restarted, at \(assembler.sampleRate) Hz")
            }
            if output.filledFrames > 0 {
                Log.info("Capture fell \(output.filledFrames) frames behind; filled with silence")
            }
            if output.skippedFrames > 0 {
                Log.info("Capture fell \(output.skippedFrames) frames behind; continuing from now")
            }
            if output.usedCurrentTime, !usingCurrentTime {
                Log.error("Can't translate Sendspin device time; using the current time")
            }
            if !output.blocks.isEmpty { usingCurrentTime = output.usedCurrentTime }
            for block in output.blocks { continuation.yield(block) }
            // A new timeline: read again from its newest frame. A full reply: there's more.
            if output.timeline == nil, reply.samples.count < Self.maxReadFrames * Self.channels { return }
        }
    }

    /// The server-clock time of a device sample time, or nil while it can't be known.
    private func captureTime(of sampleTime: Int64) -> Int64? {
        var input = AudioTimeStamp()
        input.mSampleTime = Float64(sampleTime)
        input.mFlags = .sampleTimeValid
        var output = AudioTimeStamp()
        output.mFlags = .hostTimeValid
        guard AudioDeviceTranslateTime(device.id, &input, &output) == noErr,
              output.mFlags.contains(.hostTimeValid) else { return nil }
        return ServerClock.micros(fromHostTime: output.mHostTime)
    }
}
