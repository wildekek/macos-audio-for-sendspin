import Foundation
import Testing
@testable import SendspinServerKit

struct SourceDecoderTests {
    /// Interleaved 16-bit little-endian stereo: a sine on the left, its negative on the right.
    static func pcm16(frames: Int) -> (data: Data, samples: [Int16]) {
        var samples: [Int16] = []
        for frame in 0..<frames {
            let value = Int16(12_000 * sin(Double(frame) * 2 * .pi * 440 / 48_000))
            samples += [value, -value]
        }
        return (samples.withUnsafeBytes { Data($0) }, samples)
    }

    @Test func decodesPCM() throws {
        let decoder = try #require(SourceDecoder(format: SourceFormat(codec: "pcm", channels: 2, sampleRate: 48_000, bitDepth: 24)))
        // 24-bit little-endian: 0x400000 is half scale, 0xC00000 minus half.
        let decoded = try #require(decoder.decode(Data([0x00, 0x00, 0x40, 0x00, 0x00, 0xC0])))
        #expect(decoded == [0.5, -0.5])
        #expect(decoder.decode(Data([0, 0, 0x40])) == nil)  // not a whole frame
    }

    /// Our encoder's frames decode back to the same samples: one frame per chunk, and several.
    @Test(arguments: [1, 3])
    func decodesFLACFrames(perChunk: Int) throws {
        let encoder = try #require(FLACEncoder(sampleRate: 48_000, channels: 2, bitDepth: 16, blockFrames: 960))
        let (input, samples) = Self.pcm16(frames: 960 * 8)
        // The encoder holds one block back: the first seven come out.
        let frames = encoder.encode(input)
        #expect(frames.count == 7)
        let decoder = try #require(SourceDecoder(format: SourceFormat(codec: "flac", channels: 2, sampleRate: 48_000,
                                                                      bitDepth: 16, codecHeader: encoder.codecHeader)))
        var decoded: [Float] = []
        for start in stride(from: 0, to: frames.count, by: perChunk) {
            let chunk = frames[start..<min(start + perChunk, frames.count)].reduce(Data(), +)
            #expect(FLACFrames.split(chunk)?.count == min(perChunk, frames.count - start))
            decoded += try #require(decoder.decode(chunk))
        }
        #expect(decoded.count == 7 * 960 * 2)
        #expect(zip(decoded, samples).allSatisfy { abs($0 - Float($1) / 32_768) < 1e-6 })
    }

    @Test func rejectsWhatIsNotWholeFLACFrames() throws {
        let encoder = try #require(FLACEncoder(sampleRate: 48_000, channels: 2, bitDepth: 16, blockFrames: 960))
        let frames = encoder.encode(Self.pcm16(frames: 960 * 3).data)
        #expect(FLACFrames.split(frames[0].dropLast(5)) == nil)
        #expect(FLACFrames.split(frames[0].dropFirst(1)) == nil)
        #expect(FLACFrames.split(frames[0] + frames[1]) == [frames[0], frames[1]])
    }
}
