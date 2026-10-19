import CoreAudio
import Foundation

/// Measures real lip sync: when a sound played into the Sendspin device actually comes
/// out of the speakers, compared with when apps are told it will.
///
/// It plays chirps into `output`, recording each chirp's render timestamp (the time an
/// app aims its video at, before adding the reported latency). The bridge streams them
/// to the speakers, and `microphone` hears them; see `ChirpMonitor`. The sync error is
/// `acoustic delay − reported output latency`: positive means the sound is late relative
/// to the picture. (Includes the sound's travel time, ~2.9 ms per metre.)
public enum AcousticSyncProbe {
    public typealias Measurement = ChirpMonitor.Observation

    public struct Result: Sendable {
        /// Chirps heard clearly enough to time.
        public var measurements: [Measurement]
        public var chirpsPlayed: Int
        /// Output latency the Sendspin device reports to apps (what video is delayed by).
        public var reportedOutputLatencyUs: Int64
        /// Input latency the microphone reports, already subtracted from the delays.
        public var microphoneLatencyUs: Int64

        public var medianDelayUs: Int64? {
            guard !measurements.isEmpty else { return nil }
            return measurements.map(\.delayUs).sorted()[measurements.count / 2]
        }

        public var syncErrorUs: Int64? { medianDelayUs.map { $0 - reportedOutputLatencyUs } }
    }

    /// Matches less chirp-like than this (normalized correlation) are noise, not the chirp.
    public static let minimumSimilarity = 0.3
    /// Rooms louder than this (RMS at the microphone) give unreliable results.
    public static let maximumAmbientDb = -45.0

    public enum ProbeError: Error, CustomStringConvertible {
        case tooNoisy(levelDb: Double)

        public var description: String {
            switch self {
            case .tooNoisy(let level):
                String(format: "the room is too loud for a measurement (%.0f dBFS at the microphone, "
                    + "needs ≤ %.0f): pause other audio and try again", level, maximumAmbientDb)
            }
        }
    }

    public static func measure(output: AudioDevice, microphone: AudioDevice, chirps: Int = 10,
                               interval: Duration = .seconds(2), amplitude: Float = 0.5) async throws -> Result {
        let monitor = try ChirpMonitor(output: output, microphone: microphone, interval: interval,
                                       amplitude: amplitude)
        let ambientDb = try await monitor.startListening()
        guard ambientDb <= maximumAmbientDb else {
            monitor.stop()
            throw ProbeError.tooNoisy(levelDb: ambientDb)
        }
        try monitor.startChirps()
        // Never wait forever, even if a chirp's window can't be evaluated.
        let deadline = Task {
            try? await Task.sleep(for: interval * Double(chirps + 3))
            monitor.stop()
        }
        defer { deadline.cancel() }

        var heard: [Measurement] = []
        var played = 0
        for await observation in monitor.observations {
            played = observation.chirp
            if observation.similarity >= minimumSimilarity { heard.append(observation) }
            if played >= chirps { break }
        }
        monitor.stop()
        return Result(measurements: heard, chirpsPlayed: played,
                      reportedOutputLatencyUs: output.reportedLatencyUs(scope: kAudioObjectPropertyScopeOutput),
                      microphoneLatencyUs: monitor.microphoneLatencyUs)
    }
}
