import AVFoundation
import Foundation

/// Converts the group's float audio into one player's stream format: channel mix,
/// sample-rate conversion, and integer PCM at the player's bit depth (16-bit with TPDF
/// dither), little-endian as Sendspin's PCM codec expects (24-bit packed in 3 bytes),
/// then for the `flac` codec, FLAC frames of 20 ms. PCM goes out as it comes, held back only
/// to keep each chunk between 15 and 150 ms, as a source's blocks can be any length.
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
    /// The input timestamp the anchor came from: later than it when held back by `endUs`.
    private var anchorInputUs: Int64?
    private var framesOut: Int64 = 0
    /// FLAC frames timestamped so far since the anchor.
    private var flacFramesOut: Int64 = 0
    /// PCM waiting for a long enough chunk: one MUST NOT exceed 150 ms and SHOULD NOT be
    /// shorter than 15 ms (player/v1.md, Server Audio Send Constraints).
    private var pendingPCM = Data()
    /// PCM frames sent so far since the anchor.
    private var pcmFramesOut: Int64 = 0
    /// Where the last chunk out ends: the timeline never starts again before it, also not in a
    /// pipeline for a new format that continues this one (player/v1.md, stream/start).
    private(set) var endUs: Int64?
    static let minChunkMs = 15
    static let maxChunkMs = 150
    private var dither = Dither()

    /// For stream/start: the FLAC stream header, or nil for PCM.
    var codecHeader: Data? { flac?.codecHeader }

    /// Input that strays this far from the running timeline is treated as a new start.
    static let resyncThresholdUs: Int64 = 10_000

    /// Fails if the needed sample-rate converter can't be created. `continuingAt` is where the
    /// stream's previous format ended, if this one continues it.
    init?(format: AudioFormatSpec, sourceRate: Int, sourceChannels: Int, continuingAt endUs: Int64? = nil) {
        self.format = format
        self.endUs = endUs
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

    /// Convert one input chunk into the chunks to send: PCM of 15 to 150 ms, or the FLAC frames
    /// it completed. Empty while the resampler, the encoder or a short PCM chunk is filling up.
    mutating func process(_ pcm: PCMBuffer, timestampUs: Int64) -> [Chunk] {
        let rate = Int64(format.sampleRate)
        if let anchorInputUs {
            let expectedUs = anchorInputUs + framesOut * 1_000_000 / rate
            if abs(expectedUs - timestampUs) > Self.resyncThresholdUs { restart(at: timestampUs) }
        } else {
            restart(at: timestampUs)
        }

        var samples = Self.mix(pcm.samples, from: pcm.channels, to: format.channels)
        if let resampler { samples = resampler.process(samples) }
        let frames = samples.count / format.channels
        guard frames > 0, let anchorUs else { return [] }

        framesOut += Int64(frames)
        let payload = quantize(samples)
        guard let flac else { return pcmChunks(adding: payload, anchorUs: anchorUs) }
        return flacChunks(flac.encode(payload), anchorUs: anchorUs)
    }

    /// The stream goes on in another format: what the resampler, a short PCM chunk or the FLAC
    /// encoder still holds, as this format's last chunks, which may be shorter (player/v1.md,
    /// Server Audio Send Constraints). Without it the new format would start after a gap.
    mutating func flush() -> [Chunk] {
        guard let anchorUs else { return [] }
        var chunks: [Chunk] = []
        if let tail = resampler?.flush(), tail.count >= format.channels {
            framesOut += Int64(tail.count / format.channels)
            let payload = quantize(tail)
            chunks += flac.map { flacChunks($0.encode(payload), anchorUs: anchorUs) } ?? pcmChunks(adding: payload, anchorUs: anchorUs)
        }
        if let flac {
            chunks += flacChunks(flac.flush(), anchorUs: anchorUs)
        } else if !pendingPCM.isEmpty {
            let frames = pendingPCM.count / (format.bitDepth / 8 * format.channels)
            chunks.append(Chunk(timestampUs: anchorUs + pcmFramesOut * 1_000_000 / Int64(format.sampleRate),
                                payload: pendingPCM, frames: frames))
            pcmFramesOut += Int64(frames)
            pendingPCM.removeAll()
            endUs = anchorUs + pcmFramesOut * 1_000_000 / Int64(format.sampleRate)
        }
        return chunks
    }

    /// The k-th FLAC frame out is the k-th block in, so frames are timestamped by counting; each
    /// is a full block but a stream's last, which holds what's left.
    private mutating func flacChunks(_ frames: [Data], anchorUs: Int64) -> [Chunk] {
        guard let flac else { return [] }
        let rate = Int64(format.sampleRate)
        return frames.map { frame in
            let frames = Int(min(Int64(flac.blockFrames), framesOut - flacFramesOut))
            defer {
                flacFramesOut += Int64(frames)
                endUs = anchorUs + flacFramesOut * 1_000_000 / rate
            }
            return Chunk(timestampUs: anchorUs + flacFramesOut * 1_000_000 / rate, payload: frame, frames: frames)
        }
    }

    /// The PCM chunks `payload` completes, each timestamped by the frames before it.
    private mutating func pcmChunks(adding payload: Data, anchorUs: Int64) -> [Chunk] {
        pendingPCM.append(payload)
        let rate = format.sampleRate
        let bytesPerFrame = format.bitDepth / 8 * format.channels
        var chunks: [Chunk] = []
        while pendingPCM.count / bytesPerFrame >= rate * Self.minChunkMs / 1000 {
            let frames = min(pendingPCM.count / bytesPerFrame, rate * Self.maxChunkMs / 1000)
            chunks.append(Chunk(timestampUs: anchorUs + pcmFramesOut * 1_000_000 / Int64(rate),
                                payload: Data(pendingPCM.prefix(frames * bytesPerFrame)), frames: frames))
            pendingPCM.removeFirst(frames * bytesPerFrame)
            pcmFramesOut += Int64(frames)
            endUs = anchorUs + pcmFramesOut * 1_000_000 / Int64(rate)
        }
        return chunks
    }

    private mutating func restart(at timestampUs: Int64) {
        // Never before audio already out: a chunk timestamped earlier would overlap it.
        anchorUs = max(timestampUs, endUs ?? timestampUs)
        anchorInputUs = timestampUs
        framesOut = 0
        flacFramesOut = 0
        pcmFramesOut = 0
        pendingPCM.removeAll()
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
        // In Double: 2³¹ − 1 as a Float rounds up to 2³¹, which doesn't fit an Int32.
        let minValue = -Double(fullScale), maxValue = Double(fullScale) - 1
        var output = Data(count: samples.count * bytesPerSample)
        output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for (i, sample) in samples.enumerated() {
                let exact = sample * fullScale
                // Dither only 16-bit: deeper formats are below the noise floor of any DAC. And
                // only samples that aren't 16-bit values already, so 16-bit sources and digital
                // silence pass bit-perfect: dither would only add noise to them.
                let noise = format.bitDepth == 16 && exact != exact.rounded() ? dither.next() : 0
                let scaled = (exact + noise).rounded()
                let value = Int32(max(minValue, min(maxValue, Double(scaled))))
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

    /// The input ends: what the filter still holds. The converter needs a reset after it.
    public func flush() -> [Float] {
        let channels = Int(outputFormat.channelCount)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4_096) else { return [] }
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        if let error { Log.warning("Resampler: \(error)") }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength) * channels))
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
