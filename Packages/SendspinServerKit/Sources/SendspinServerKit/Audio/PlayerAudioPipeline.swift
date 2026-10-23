import AVFoundation
import Foundation

/// Converts the group's float audio into one player's stream format: channel mix,
/// sample-rate conversion, and integer PCM at the player's bit depth (16-bit with TPDF
/// dither), little-endian as Sendspin's PCM codec expects (24-bit packed in 3 bytes),
/// then for the `flac` codec, FLAC frames of 20 ms.
///
/// Output chunks are timestamped from a running frame count, so they stay
/// sample-contiguous even though resampling changes chunk lengths. The timeline
/// re-anchors to the input's timestamps only after a real gap in the input.
struct PlayerAudioPipeline {
    struct Chunk {
        var timestampUs: Int64
        var payload: Data
        /// Samples per channel, for the chunk's duration.
        var frames: Int
    }

    let format: AudioFormatSpec
    private let sourceRate: Int
    private let sourceChannels: Int
    private var resampler: Resampler?
    private var flac: FLACEncoder?
    private var anchorUs: Int64?
    private var framesOut: Int64 = 0
    /// FLAC frames timestamped so far since the anchor.
    private var flacFramesOut: Int64 = 0
    private var dither = Dither()

    /// For stream/start: the FLAC stream header, or nil for PCM.
    var codecHeader: Data? { flac?.codecHeader }

    /// Input that strays this far from the running timeline is treated as a new start.
    static let resyncThresholdUs: Int64 = 10_000

    /// Fails if the needed sample-rate converter can't be created.
    init?(format: AudioFormatSpec, sourceRate: Int, sourceChannels: Int) {
        self.format = format
        self.sourceRate = sourceRate
        self.sourceChannels = sourceChannels
        if sourceRate != format.sampleRate {
            guard let resampler = Resampler(from: sourceRate, to: format.sampleRate, channels: format.channels)
            else { return nil }
            self.resampler = resampler
        }
        if format.codec == AudioCodec.flac.rawValue {
            guard let flac = Self.makeFLAC(format) else { return nil }
            self.flac = flac
        }
    }

    private static func makeFLAC(_ format: AudioFormatSpec) -> FLACEncoder? {
        FLACEncoder(sampleRate: format.sampleRate, channels: format.channels, bitDepth: format.bitDepth,
                    blockFrames: format.sampleRate / 50)
    }

    func accepts(_ pcm: PCMBuffer) -> Bool {
        pcm.sampleRate == sourceRate && pcm.channels == sourceChannels
    }

    /// Convert one input chunk into the chunks to send: one for PCM, or the FLAC frames it
    /// completed. Empty while the resampler or the FLAC encoder is still filling up.
    mutating func process(_ pcm: PCMBuffer, timestampUs: Int64) -> [Chunk] {
        let rate = Int64(format.sampleRate)
        if let anchorUs {
            let expectedUs = anchorUs + framesOut * 1_000_000 / rate
            if abs(expectedUs - timestampUs) > Self.resyncThresholdUs { restart(at: timestampUs) }
        } else {
            restart(at: timestampUs)
        }

        var samples = Self.mix(pcm.samples, from: pcm.channels, to: format.channels)
        if let resampler { samples = resampler.process(samples) }
        let frames = samples.count / format.channels
        guard frames > 0, let anchorUs else { return [] }

        let outputTimestamp = anchorUs + framesOut * 1_000_000 / rate
        framesOut += Int64(frames)
        let payload = quantize(samples)
        guard let flac else { return [Chunk(timestampUs: outputTimestamp, payload: payload, frames: frames)] }
        // The k-th FLAC frame out is the k-th block in, so count frames for their timestamps.
        return flac.encode(payload).map { frame in
            defer { flacFramesOut += Int64(flac.blockFrames) }
            return Chunk(timestampUs: anchorUs + flacFramesOut * 1_000_000 / rate, payload: frame,
                         frames: flac.blockFrames)
        }
    }

    private mutating func restart(at timestampUs: Int64) {
        anchorUs = timestampUs
        framesOut = 0
        flacFramesOut = 0
        resampler?.reset()
        // A new encoder: the old one still holds a block from before the gap.
        if flac != nil { flac = Self.makeFLAC(format) }
    }

    static func mix(_ samples: [Float], from inChannels: Int, to outChannels: Int) -> [Float] {
        if inChannels == outChannels { return samples }
        let frames = samples.count / inChannels
        var output = [Float](repeating: 0, count: frames * outChannels)
        for frame in 0..<frames {
            let base = frame * inChannels
            if outChannels == 1 {
                // Downmix: average all input channels.
                var sum: Float = 0
                for c in 0..<inChannels { sum += samples[base + c] }
                output[frame] = sum / Float(inChannels)
            } else {
                // Upmix: repeat the nearest input channel.
                for c in 0..<outChannels { output[frame * outChannels + c] = samples[base + min(c, inChannels - 1)] }
            }
        }
        return output
    }

    private mutating func quantize(_ samples: [Float]) -> Data {
        let bytesPerSample = format.bitDepth / 8
        let fullScale = Float(Int64(1) << (format.bitDepth - 1))
        let maxValue = fullScale - 1
        var output = Data(count: samples.count * bytesPerSample)
        output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (i, sample) in samples.enumerated() {
                let exact = sample * fullScale
                // Dither only 16-bit: deeper formats are below the noise floor of any DAC. And
                // only samples that aren't 16-bit values already, so 16-bit sources and digital
                // silence pass bit-perfect: dither would only add noise to them.
                let noise = format.bitDepth == 16 && exact != exact.rounded() ? dither.next() : 0
                let scaled = (exact + noise).rounded()
                let value = Int32(max(-fullScale, min(maxValue, scaled)))
                let offset = i * bytesPerSample
                for byte in 0..<bytesPerSample {
                    bytes[offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * byte))
                }
            }
        }
        return output
    }
}

/// Triangular (TPDF) dither of ±1 LSB from a small xorshift generator.
private struct Dither {
    private var state: UInt32 = 0x9E37_79B9

    mutating func next() -> Float {
        uniform() - uniform()
    }

    private mutating func uniform() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(state) / Float(UInt32.max)
    }
}

/// Streaming sample-rate converter for interleaved float audio. Keeps the filter state
/// between chunks, so consecutive chunks join seamlessly.
public final class Resampler {
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let ratio: Double

    public init?(from inputRate: Int, to outputRate: Int, channels: Int) {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(inputRate),
                                        channels: AVAudioChannelCount(channels), interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(outputRate),
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        // Normal priming: the output is time-aligned with the input (no added delay).
        converter.primeMethod = .normal
        self.converter = converter
        inputFormat = input
        outputFormat = output
        ratio = Double(outputRate) / Double(inputRate)
    }

    public func reset() {
        converter.reset()
    }

    public func process(_ samples: [Float]) -> [Float] {
        let channels = Int(inputFormat.channelCount)
        let inputFrames = samples.count / channels
        guard inputFrames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(inputFrames)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(inputFrames) * ratio) + 64)
        else { return [] }
        input.frameLength = AVAudioFrameCount(inputFrames)
        samples.withUnsafeBufferPointer { source in
            input.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { Log.warning("Resampler: \(error)") }
        let count = Int(output.frameLength) * channels
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: count))
    }
}
