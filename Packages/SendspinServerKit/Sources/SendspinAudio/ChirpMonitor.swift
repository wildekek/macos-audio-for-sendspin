import CoreAudio
import Foundation
import SendspinServerKit

/// Plays a chirp every `interval` into an output device and, for every chirp, reports
/// how clearly the microphone heard it and when — as it happens.
///
/// `delayUs` is the time from the chirp's render timestamp (what an app schedules
/// against) to the moment the sound reached the microphone, after subtracting the
/// microphone's reported input latency. Delays must be shorter than `interval`.
public final class ChirpMonitor: @unchecked Sendable {
    public struct Observation: Sendable {
        public var chirp: Int
        public var delayUs: Int64
        /// How chirp-like the best match was (normalized correlation, 0…1).
        public var similarity: Double
    }

    public let observations: AsyncStream<Observation>
    public let microphoneLatencyUs: Int64
    public let chirp: [Float32]

    private let output: AudioDevice
    private let interval: Duration
    private let intervalFrames: Int
    private let recording = MicRecording()
    private let capture: AudioCapture
    private let continuation: AsyncStream<Observation>.Continuation
    private var player: SignalPlayer?
    private var tasks: [Task<Void, Never>] = []

    public init(output: AudioDevice, microphone: AudioDevice, interval: Duration = .seconds(1),
                amplitude: Float = 0.5) throws {
        self.output = output
        self.interval = interval
        intervalFrames = Int(interval / .milliseconds(1)) * ChirpMatching.sampleRate / 1000
        chirp = ChirpMatching.chirp(amplitude: amplitude)
        microphoneLatencyUs = microphone.reportedLatencyUs(scope: kAudioObjectPropertyScopeInput)
        capture = try AudioCapture(device: microphone, sampleRate: ChirpMatching.sampleRate, blockMs: 20)
        (observations, continuation) = AsyncStream.makeStream()
    }

    /// Start listening; returns the room level (dBFS) measured over `listenFirst`, before
    /// any chirp is played. Call `startChirps()` next.
    public func startListening(listenFirst: Duration = .seconds(1)) async throws -> Double {
        let recording = recording
        let blocks = capture.blocks
        tasks.append(Task { for await block in blocks { recording.append(block) } })
        try capture.start()
        try await Task.sleep(for: listenFirst)
        return recording.levelDb()
    }

    public func startChirps() throws {
        let player = try SignalPlayer(device: output, signal: chirp, intervalFrames: intervalFrames)
        try player.start()
        self.player = player
        tasks.append(Task { [weak self] in await self?.evaluateChirps(player) })
    }

    public func stop() {
        player?.stop()
        capture.stop()
        tasks.forEach { $0.cancel() }
        continuation.finish()
        if let path = ProcessInfo.processInfo.environment["SENDSPIN_PROBE_DUMP"], let player {
            recording.dump(to: URL(filePath: path), chirpStartsUs: player.startTimesUs, chirp: chirp)
        }
    }

    /// Once a chirp's whole window has been recorded, find it in that window.
    private func evaluateChirps(_ player: SignalPlayer) async {
        let windowUs = Int64(interval / .microseconds(1))
        var evaluated = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            let starts = player.startTimesUs
            while evaluated < starts.count {
                let startUs = starts[evaluated]
                // Wait until the window plus the chirp's own length has been captured.
                guard ServerClock.nowMicros() > startUs + windowUs + 150_000,
                      let first = recording.index(atUs: startUs),
                      let samples = recording.samples(from: first, count: intervalFrames + chirp.count) else { break }
                if let match = ChirpMatching.bestMatch(of: chirp, in: samples),
                   let heardUs = recording.timeUs(atIndex: first + match.offset) {
                    continuation.yield(Observation(chirp: evaluated + 1,
                                                   delayUs: heardUs - microphoneLatencyUs - startUs,
                                                   similarity: Double(match.similarity)))
                }
                evaluated += 1
            }
        }
    }
}
