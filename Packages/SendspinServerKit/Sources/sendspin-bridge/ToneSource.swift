import Foundation
import SendspinAudio
import SendspinServerKit

/// A real-time paced sine tone, for testing without an audio device.
enum ToneSource {
    static func blocks(frequency: Double = 440, amplitudeDb: Double = -20,
                       sampleRate: Int = 48_000, blockMs: Int = 20) -> AsyncStream<CapturedBlock> {
        AsyncStream { continuation in
            let task = Task {
                let framesPerBlock = sampleRate * blockMs / 1000
                let amplitude = pow(10, amplitudeDb / 20)
                let start = ServerClock.nowMicros()
                var frameIndex = 0
                while !Task.isCancelled {
                    var samples = [Float](repeating: 0, count: framesPerBlock * 2)
                    for i in 0..<framesPerBlock {
                        let t = Double(frameIndex + i) / Double(sampleRate)
                        let value = Float(amplitude * sin(2 * .pi * frequency * t))
                        samples[2 * i] = value
                        samples[2 * i + 1] = value
                    }
                    let captureTime = start + Int64(frameIndex) * 1_000_000 / Int64(sampleRate)
                    continuation.yield(CapturedBlock(
                        pcm: PCMBuffer(samples: samples, sampleRate: sampleRate, channels: 2),
                        captureTimeUs: captureTime))
                    frameIndex += framesPerBlock
                    // Pace like a real device: emit each block once it has "been recorded".
                    let nextDue = start + Int64(frameIndex) * 1_000_000 / Int64(sampleRate)
                    let wait = nextDue - ServerClock.nowMicros()
                    if wait > 0 { try? await Task.sleep(for: .microseconds(wait)) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
