import Accelerate
import Foundation

/// Microphone samples (first channel) with the capture timestamp of every block, so
/// any sample index maps back to host time.
public final class MicRecording: @unchecked Sendable {
    public static let sampleRate = ChirpMatching.sampleRate

    private let lock = NSLock()
    private var samples: [Float] = []
    private var blocks: [(start: Int, timeUs: Int64)] = []

    public init() {}

    public func append(_ block: CapturedBlock) {
        let channels = block.pcm.channels
        let all = block.pcm.samples
        let mono = stride(from: 0, to: all.count, by: channels).map { all[$0] }
        lock.withLock {
            blocks.append((samples.count, block.captureTimeUs))
            samples.append(contentsOf: mono)
        }
    }

    public var count: Int { lock.withLock { samples.count } }

    public func samples(from start: Int, count: Int) -> [Float]? {
        lock.withLock {
            guard start >= 0, start + count <= samples.count else { return nil }
            return Array(samples[start..<(start + count)])
        }
    }

    /// RMS level of everything recorded so far, dBFS.
    public func levelDb() -> Double {
        lock.withLock {
            guard !samples.isEmpty else { return -.infinity }
            var meanSquare: Float = 0
            vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
            return 10 * log10(Double(meanSquare) + 1e-12)
        }
    }

    public func index(atUs time: Int64) -> Int? {
        lock.withLock {
            guard let block = blocks.last(where: { $0.timeUs <= time }) else { return nil }
            return block.start + Int((time - block.timeUs) * Int64(Self.sampleRate) / 1_000_000)
        }
    }

    public func timeUs(atIndex index: Int) -> Int64? {
        lock.withLock {
            guard let block = blocks.last(where: { $0.start <= index }) else { return nil }
            return block.timeUs + Int64(index - block.start) * 1_000_000 / Int64(Self.sampleRate)
        }
    }

    /// Debug aid: write samples, block timestamps and chirp times as JSON for offline analysis.
    func dump(to url: URL, chirpStartsUs: [Int64], chirp: [Float32]) {
        lock.withLock {
            let object: [String: Any] = [
                "sampleRate": Self.sampleRate,
                "samples": samples,
                "blockStarts": blocks.map(\.start),
                "blockTimesUs": blocks.map(\.timeUs),
                "chirpStartsUs": chirpStartsUs,
                "chirp": chirp,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: object) { try? data.write(to: url) }
        }
    }
}
