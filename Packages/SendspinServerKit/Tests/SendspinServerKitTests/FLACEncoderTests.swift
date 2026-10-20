import AudioToolbox
import Foundation
import Testing
@testable import SendspinServerKit

struct FLACEncoderTests {
    /// One second of a tone with noise, interleaved little-endian PCM.
    static func pcm(rate: Int, channels: Int, bitDepth: Int) -> Data {
        let bytes = bitDepth / 8
        let scale = Double(1 << (bitDepth - 1)) * 0.25
        var data = Data(capacity: rate * channels * bytes)
        var noise: UInt32 = 0x1234_5678
        for i in 0..<rate {
            for c in 0..<channels {
                noise = noise &* 1_664_525 &+ 1_013_904_223
                let value = Int32(sin(2 * .pi * 440 * Double(i) / Double(rate) + Double(c)) * scale)
                    + Int32(noise >> 24) - 128
                for b in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * b))) }
            }
        }
        return data
    }

    @Test(arguments: [16, 24])
    func roundTripsBitExactly(bitDepth: Int) throws {
        let rate = 48_000, channels = 2, block = 960
        let input = Self.pcm(rate: rate, channels: channels, bitDepth: bitDepth)
        let encoder = try #require(FLACEncoder(sampleRate: rate, channels: channels, bitDepth: bitDepth, blockFrames: block))

        // Fed in uneven pieces, it still emits whole blocks.
        var frames: [Data] = []
        var offset = 0
        for piece in [1234, 999, 5000, 333].cycled(until: input.count) {
            let end = min(offset + piece, input.count)
            frames += encoder.encode(input[offset..<end])
            offset = end
        }
        // The encoder holds one block back, released by the next one.
        #expect(frames.count == rate / block - 1)
        for frame in frames {
            #expect(frame.prefix(2) == Data([0xFF, 0xF8]))  // frame sync code, fixed block size
        }

        let header = encoder.codecHeader
        #expect(header.prefix(4) == Data("fLaC".utf8))
        #expect(header[4] == 0x80 && header[5...7] == Data([0x00, 0x00, 0x22]))  // last block: STREAMINFO, 34 bytes
        #expect(header.count == 4 + 4 + 34)

        let decoded = try Self.decode(frames, header: header, rate: rate, channels: channels, bitDepth: bitDepth,
                                      block: block)
        #expect(decoded == input.prefix(frames.count * block * channels * bitDepth / 8))
    }

    @Test func rejectsUnsupportedBitDepths() {
        #expect(FLACEncoder(sampleRate: 48_000, channels: 2, bitDepth: 32, blockFrames: 960) == nil)
    }

    /// Decode with AudioToolbox's FLAC decoder, fed the stream's own STREAMINFO.
    static func decode(_ frames: [Data], header: Data, rate: Int, channels: Int, bitDepth: Int,
                       block: Int) throws -> Data {
        var input = AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: kAudioFormatFLAC,
            mFormatFlags: bitDepth == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(block), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        let bytesPerFrame = channels * bitDepth / 8
        var output = AudioStreamBasicDescription(
            mSampleRate: Double(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bitDepth), mReserved: 0)
        var converter: AudioConverterRef?
        try #require(AudioConverterNew(&input, &output, &converter) == noErr)
        defer { AudioConverterDispose(converter!) }
        // The decoder's cookie is the same 'dfLa' atom the encoder made: rebuild it from the header.
        var cookie = Data()
        let atom = header.dropFirst(4)
        withUnsafeBytes(of: UInt32(12 + atom.count).bigEndian) { cookie.append(contentsOf: $0) }
        cookie.append(contentsOf: Array("dfLa".utf8) + [0, 0, 0, 0])
        cookie.append(atom)
        _ = cookie.withUnsafeBytes {
            AudioConverterSetProperty(converter!, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
        }

        final class Source {
            var frames: [Data]
            var index = 0
            var current: UnsafeMutableRawBufferPointer?
            var description = AudioStreamPacketDescription()
            init(_ frames: [Data]) { self.frames = frames }
        }
        let source = Source(frames)
        var decoded = Data()
        var buffer = [UInt8](repeating: 0, count: block * bytesPerFrame)
        while true {
            var packets = UInt32(block)
            let status = buffer.withUnsafeMutableBytes { raw -> OSStatus in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
                return AudioConverterFillComplexBuffer(converter!, { _, ioPackets, ioData, ioDescriptions, user in
                    let source = Unmanaged<Source>.fromOpaque(user!).takeUnretainedValue()
                    source.current?.deallocate()
                    source.current = nil
                    guard source.index < source.frames.count else {
                        ioPackets.pointee = 0
                        return 1
                    }
                    let frame = source.frames[source.index]
                    source.index += 1
                    let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount: frame.count, alignment: 4)
                    frame.copyBytes(to: bytes)
                    source.current = bytes
                    ioData.pointee.mBuffers.mData = bytes.baseAddress
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(frame.count)
                    source.description = AudioStreamPacketDescription(
                        mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count))
                    ioDescriptions?.pointee = withUnsafeMutablePointer(to: &source.description) { $0 }
                    ioPackets.pointee = 1
                    return noErr
                }, Unmanaged.passUnretained(source).toOpaque(), &packets, &list, nil)
            }
            decoded.append(contentsOf: buffer.prefix(Int(packets) * bytesPerFrame))
            if packets == 0 || status != noErr { break }
        }
        source.current?.deallocate()
        return decoded
    }
}

private extension Array where Element == Int {
    /// Repeat the sizes until they add up to at least `total`.
    func cycled(until total: Int) -> [Int] {
        var result: [Int] = []
        var sum = 0
        while sum < total {
            for size in self where sum < total {
                result.append(size)
                sum += size
            }
        }
        return result
    }
}
