import CoreAudio
import Foundation
import SendspinServerKit

/// Checks what a sample-rate switch does to the Sendspin device: switches through every rate
/// it offers while `DriverCapture` reads it, and checks for each that the device's timeline
/// restarted exactly once (every configuration change restarts its IO, a gap in the audio),
/// that the latency apps see stays the same duration, and that capture carries on at the new
/// rate. Puts back the rate and latency it found.
public enum RateSwitchCheck {
    public struct Switch: Sendable {
        public var sampleRate: Int
        public var timelineRestarts: Int
        public var reportedLatencyUs: Int64
        /// The rate of the last captured block, nil if none came.
        public var capturedRate: Int?

        public func passed(latencyUs: Int) -> Bool {
            timelineRestarts == 1 && abs(reportedLatencyUs - Int64(latencyUs)) < 100 && capturedRate == sampleRate
        }
    }

    public struct Result: Sendable {
        public var latencyUs: Int
        public var switches: [Switch]
        public var passed: Bool { !switches.isEmpty && switches.allSatisfy { $0.passed(latencyUs: latencyUs) } }
    }

    public static func run(device: AudioDevice, latencyUs: Int = 250_000) async throws -> Result {
        let originalRate = device.nominalSampleRate
        let originalLatency = device.presentationLatencyMicroseconds
        defer {
            try? device.setNominalSampleRate(originalRate)
            if let originalLatency { try? device.setPresentationLatency(microseconds: originalLatency) }
        }
        try device.setPresentationLatency(microseconds: latencyUs)

        let capture = try DriverCapture(device: device)
        let lastRate = LastRate()
        let reader = Task { for await block in capture.blocks { lastRate.set(block.pcm.sampleRate) } }
        defer {
            capture.stop()
            reader.cancel()
        }
        try capture.start()
        try await Task.sleep(for: .seconds(1)) // the latency change restarts the timeline too

        // Every rate once, ending where it started.
        let rates = device.availableSampleRates.map(Int.init).filter { $0 != Int(originalRate) } + [Int(originalRate)]
        var switches: [Switch] = []
        for rate in rates {
            let restartsBefore = capture.timelineRestartCount
            try device.setNominalSampleRate(Double(rate))
            for _ in 0..<30 where Int(device.nominalSampleRate) != rate {
                try await Task.sleep(for: .milliseconds(100))
            }
            try await Task.sleep(for: .seconds(1))
            switches.append(Switch(sampleRate: rate, timelineRestarts: capture.timelineRestartCount - restartsBefore,
                                   reportedLatencyUs: device.reportedLatencyUs(scope: kAudioObjectPropertyScopeOutput),
                                   capturedRate: lastRate.get()))
        }
        return Result(latencyUs: latencyUs, switches: switches)
    }

    private final class LastRate: @unchecked Sendable {
        private let lock = NSLock()
        private var rate: Int?
        func set(_ value: Int) { lock.withLock { rate = value } }
        func get() -> Int? { lock.withLock { rate } }
    }
}
