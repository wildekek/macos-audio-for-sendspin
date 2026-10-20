import AudioToolbox
import Foundation

/// FLAC frames from interleaved little-endian integer PCM (16-bit, or 24-bit packed in 3
/// bytes), with AudioToolbox's encoder. Every frame holds `blockFrames` samples per channel;
/// input is buffered until a frame is full, so each output is one complete FLAC frame, as
/// a Sendspin audio chunk must carry (roles/player/v1.md, Codec framing). The encoder holds
/// one block back: each block comes out when the next one goes in (20 ms more latency).
final class FLACEncoder {
    static let bitDepths = [16, 24]

    let blockFrames: Int
    /// For stream/start: the `fLaC` marker and the STREAMINFO metadata block.
    let codecHeader: Data

    private let converter: AudioConverterRef
    private let bytesPerFrame: Int
    private let maxPacketSize: Int
    private var pending = Data()

    /// One block of PCM for the converter's input callback, in memory that stays valid
    /// after the callback returns: the converter reads it afterwards.
    private final class Feed {
        let bytes: UnsafeMutableRawBufferPointer
        let frames: Int
        var consumed = false

        init(_ block: Data, frames: Int) {
            bytes = .allocate(byteCount: block.count, alignment: 4)
            block.copyBytes(to: bytes)
            self.frames = frames
        }

        deinit {
            bytes.deallocate()
        }
    }

    /// Returned by the input callback once its block is used: "no more input for now".
    private static let noMoreInput: OSStatus = 0x6E6D_6F72  // 'nmor'

    init?(sampleRate: Int, channels: Int, bitDepth: Int, blockFrames: Int) {
        guard Self.bitDepths.contains(bitDepth) else { return nil }
        self.blockFrames = blockFrames
        bytesPerFrame = channels * bitDepth / 8
        var input = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame), mFramesPerPacket: 1, mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(bitDepth), mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatFLAC,
            mFormatFlags: bitDepth == 16 ? kAppleLosslessFormatFlag_16BitSourceData : kAppleLosslessFormatFlag_24BitSourceData,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(blockFrames), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var converter: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &converter) == noErr, let converter else { return nil }
        self.converter = converter

        var size = UInt32(MemoryLayout<UInt32>.size)
        var maxPacket: UInt32 = 0
        AudioConverterGetProperty(converter, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxPacket)
        maxPacketSize = max(Int(maxPacket), blockFrames * bytesPerFrame + 1024)

        // The magic cookie is a 'dfLa' atom: size, type, version and flags, then the
        // metadata blocks. Sendspin's codec_header is "fLaC" followed by those blocks.
        var cookieSize: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterCompressionMagicCookie, &cookieSize, nil) == noErr,
              cookieSize > 12
        else { AudioConverterDispose(converter); return nil }
        var cookie = Data(count: Int(cookieSize))
        let status = cookie.withUnsafeMutableBytes {
            AudioConverterGetProperty(converter, kAudioConverterCompressionMagicCookie, &cookieSize, $0.baseAddress!)
        }
        guard status == noErr, cookie[4..<8] == Data("dfLa".utf8) else { AudioConverterDispose(converter); return nil }
        codecHeader = Data("fLaC".utf8) + cookie[12..<Int(cookieSize)]
    }

    deinit {
        AudioConverterDispose(converter)
    }

    /// Add PCM; returns the FLAC frames completed by it, oldest first. The k-th frame out
    /// is always the k-th block in, so callers can timestamp frames by counting them.
    func encode(_ pcm: Data) -> [Data] {
        pending.append(pcm)
        let blockBytes = blockFrames * bytesPerFrame
        var frames: [Data] = []
        while pending.count >= blockBytes {
            let feed = Feed(pending.prefix(blockBytes), frames: blockFrames)
            pending.removeFirst(blockBytes)
            if let frame = encodeBlock(feed) { frames.append(frame) }
        }
        return frames
    }

    /// Drop buffered input that didn't make a full frame yet.
    func reset() {
        pending.removeAll()
    }

    private func encodeBlock(_ feed: Feed) -> Data? {
        var output = Data(count: maxPacketSize)
        var packets: UInt32 = 1
        var description = AudioStreamPacketDescription()
        let status = output.withUnsafeMutableBytes { raw -> OSStatus in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 0, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
            return withExtendedLifetime(feed) {
                AudioConverterFillComplexBuffer(converter, { _, ioPackets, ioData, _, userData in
                    let feed = Unmanaged<Feed>.fromOpaque(userData!).takeUnretainedValue()
                    guard !feed.consumed else {
                        ioPackets.pointee = 0
                        ioData.pointee.mBuffers.mDataByteSize = 0
                        return FLACEncoder.noMoreInput
                    }
                    feed.consumed = true
                    ioData.pointee.mBuffers.mData = feed.bytes.baseAddress
                    ioData.pointee.mBuffers.mDataByteSize = UInt32(feed.bytes.count)
                    ioPackets.pointee = UInt32(feed.frames)
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &packets, &buffers, &description)
            }
        }
        guard status == noErr || status == Self.noMoreInput else {
            Log.error("FLAC encoder: status \(status)")
            return nil
        }
        guard packets == 1 else { return nil }  // the first block stays in the encoder
        let start = Int(description.mStartOffset)
        return Data(output[start..<start + Int(description.mDataByteSize)])
    }
}
