import AudioToolbox
import Foundation

/// The format of a source's input stream, from client-stream/start (roles/source/v1.md).
public struct SourceFormat: Sendable, Equatable {
    public var codec: String
    public var channels: Int
    public var sampleRate: Int
    public var bitDepth: Int
    /// For FLAC: the `fLaC` marker and the STREAMINFO block.
    public var codecHeader: Data?

    public init(codec: String, channels: Int, sampleRate: Int, bitDepth: Int, codecHeader: Data? = nil) {
        self.codec = codec
        self.channels = channels
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.codecHeader = codecHeader
    }
}

/// Decodes a source's audio chunks to interleaved float samples: PCM (little-endian signed,
/// any whole number of bytes per sample) or FLAC, the two codecs every server must accept.
/// A FLAC chunk holds one or more complete frames; each goes to AudioToolbox's decoder as one
/// packet.
final class SourceDecoder {
    let format: SourceFormat
    private var flac: FLACDecoder?

    /// Fails for a codec or format we can't decode.
    init?(format: SourceFormat) {
        guard (1...8).contains(format.channels), (8_000...384_000).contains(format.sampleRate) else { return nil }
        self.format = format
        switch format.codec {
        case AudioCodec.pcm.rawValue:
            guard [8, 16, 24, 32].contains(format.bitDepth) else { return nil }
        case AudioCodec.flac.rawValue:
            guard let header = format.codecHeader, let flac = FLACDecoder(format: format, header: header) else { return nil }
            self.flac = flac
        default:
            return nil
        }
    }

    /// The chunk's samples, or nil when it doesn't decode (not whole frames, or corrupt).
    func decode(_ chunk: Data) -> [Float]? {
        if let flac { return flac.decode(chunk) }
        let bytes = format.bitDepth / 8
        guard chunk.count % (bytes * format.channels) == 0 else { return nil }
        let scale = 1 / Float(1 << (format.bitDepth - 1))
        return chunk.withUnsafeBytes { raw in
            (0..<chunk.count / bytes).map { index in
                var value: Int32 = 0
                for byte in 0..<bytes { value |= Int32(raw[index * bytes + byte]) << (8 * byte) }
                // Sign-extend from the sample's width.
                let shift = Int32(32 - format.bitDepth)
                return Float((value << shift) >> shift) * scale
            }
        }
    }
}

/// AudioToolbox's FLAC decoder, fed one frame at a time.
private final class FLACDecoder {
    private let converter: AudioConverterRef
    private let channels: Int
    private let maxBlockFrames: Int

    init?(format: SourceFormat, header: Data) {
        // "fLaC", then metadata blocks: STREAMINFO first, its block sizes at bytes 8 ..< 12.
        guard header.count >= 42, header.prefix(4) == Data("fLaC".utf8), header[header.startIndex + 4] & 0x7F == 0
        else { return nil }
        let start = header.startIndex
        maxBlockFrames = max(16, Int(header[start + 10]) << 8 | Int(header[start + 11]))
        channels = format.channels
        var input = AudioStreamBasicDescription(
            mSampleRate: Double(format.sampleRate), mFormatID: kAudioFormatFLAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(maxBlockFrames), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        let bytesPerFrame = UInt32(4 * channels)
        var output = AudioStreamBasicDescription(
            mSampleRate: Double(format.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        self.converter = converter
        // The cookie is a 'dfLa' atom: size, type, version and flags, then the metadata blocks
        // (the encoder's, the other way round).
        let blocks = header.dropFirst(4)
        var cookie = Data()
        withUnsafeBytes(of: UInt32(12 + blocks.count).bigEndian) { cookie.append(contentsOf: $0) }
        cookie += Data("dfLa".utf8) + Data([0, 0, 0, 0]) + blocks
        let status = cookie.withUnsafeBytes {
            AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookie.count), $0.baseAddress!)
        }
        guard status == noErr else {
            AudioConverterDispose(converter)
            return nil
        }
    }

    deinit {
        AudioConverterDispose(converter)
    }

    func decode(_ chunk: Data) -> [Float]? {
        guard let frames = FLACFrames.split(chunk) else { return nil }
        var samples: [Float] = []
        for frame in frames {
            guard let decoded = decodeFrame(frame) else { return nil }
            samples += decoded
        }
        return samples
    }

    /// One packet in for the converter's input callback, kept valid until it's read.
    private final class Packet {
        let bytes: UnsafeMutableRawBufferPointer
        let description: UnsafeMutablePointer<AudioStreamPacketDescription>
        var consumed = false

        init(_ frame: Data) {
            bytes = .allocate(byteCount: frame.count, alignment: 4)
            frame.copyBytes(to: bytes)
            description = .allocate(capacity: 1)
            description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(frame.count)))
        }

        deinit {
            bytes.deallocate()
            description.deallocate()
        }
    }

    private static let noMoreInput: OSStatus = 0x6E6D_6F72  // 'nmor'

    private func decodeFrame(_ frame: Data) -> [Float]? {
        let packet = Packet(frame)
        var samples = [Float](repeating: 0, count: maxBlockFrames * channels)
        var frames = UInt32(maxBlockFrames)
        let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return withExtendedLifetime(packet) {
                AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, descriptions, userData in
                    let packet = Unmanaged<Packet>.fromOpaque(userData!).takeUnretainedValue()
                    guard !packet.consumed else {
                        ioPackets.pointee = 0
                        ioData.pointee.mBuffers.mDataByteSize = 0
                        return FLACDecoder.noMoreInput
                    }
                    packet.consumed = true
                    ioData.pointee.mBuffers.mData = packet.bytes.baseAddress
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(packet.bytes.count)
                    ioPackets.pointee = 1
                    descriptions?.pointee = packet.description
                    return noErr
                }, Unmanaged.passUnretained(packet).toOpaque(), &frames, &buffers, nil)
            }
        }
        guard status == noErr || status == Self.noMoreInput else { return nil }
        return Array(samples.prefix(Int(frames) * channels))
    }
}

/// Where the FLAC frames in a chunk start and end. A frame starts with a header (sync code,
/// checked by its CRC-8) and ends with a CRC-16 of the whole frame; a header-like pattern
/// inside a frame doesn't pass both.
enum FLACFrames {
    static func split(_ chunk: Data) -> [Data]? {
        let bytes = [UInt8](chunk)
        guard headerLength(bytes, at: 0) != nil else { return nil }
        var frames: [Data] = []
        var start = 0
        while start < bytes.count {
            var end: Int?
            var candidate = start + 1
            while candidate <= bytes.count {
                if candidate == bytes.count || headerLength(bytes, at: candidate) != nil, candidate - start >= 4,
                   crc16(bytes[start..<candidate - 2]) == UInt16(bytes[candidate - 2]) << 8 | UInt16(bytes[candidate - 1]) {
                    end = candidate
                    break
                }
                candidate += 1
            }
            guard let end else { return nil }
            frames.append(Data(bytes[start..<end]))
            start = end
        }
        return frames
    }

    /// The length of a valid frame header at `offset`, CRC-8 included.
    static func headerLength(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset + 5 < bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] & 0xFE == 0xF8 else { return nil }
        let blockCode = bytes[offset + 2] >> 4, rateCode = bytes[offset + 2] & 0x0F
        let channelCode = bytes[offset + 3] >> 4, sizeCode = (bytes[offset + 3] >> 1) & 0x07
        guard blockCode != 0, rateCode != 0x0F, channelCode <= 10, sizeCode != 3, bytes[offset + 3] & 1 == 0 else { return nil }
        // The frame or sample number, UTF-8 coded: its first byte gives its length.
        let first = bytes[offset + 4]
        let numberLength = first & 0x80 == 0 ? 1 : (~first).leadingZeroBitCount
        guard (1...7).contains(numberLength), numberLength > 1 || first & 0x80 == 0 else { return nil }
        var length = 4 + numberLength
        length += blockCode == 6 ? 1 : blockCode == 7 ? 2 : 0
        length += rateCode == 12 ? 1 : rateCode == 13 || rateCode == 14 ? 2 : 0
        guard offset + length < bytes.count, crc8(bytes[offset..<offset + length]) == bytes[offset + length] else { return nil }
        return length + 1
    }

    static func crc8(_ bytes: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0
        for byte in bytes {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x8005 : crc << 1 }
        }
        return crc
    }
}
