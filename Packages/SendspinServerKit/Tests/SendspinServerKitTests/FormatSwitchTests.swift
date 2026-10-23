import Testing
@testable import SendspinServerKit

struct FormatSwitchTests {
    @Test func aBitDepthAtTheSameRateGoesStraightAway() {
        var formats = FormatSwitch()
        #expect(formats.select(sampleRate: 48_000, bitDepth: 24, deviceRate: 48_000)
            == [.setBitDepth(24, fromSampleRate: nil)])
        #expect(formats.waitingBitDepth == nil)
    }

    @Test func withANewRateTheGroupHearsFirstAndWaitsForIt() {
        var formats = FormatSwitch()
        #expect(formats.select(sampleRate: 96_000, bitDepth: 24, deviceRate: 48_000)
            == [.setBitDepth(24, fromSampleRate: 96_000), .setDeviceRate(96_000)])
        #expect(formats.waitingBitDepth == 24)
        formats.deviceRateChanged()
        #expect(formats.waitingBitDepth == nil)
    }

    @Test func aFailedRateChangeLetsTheBitDepthGo() {
        var formats = FormatSwitch()
        _ = formats.select(sampleRate: 192_000, bitDepth: 16, deviceRate: 44_100)
        #expect(formats.deviceRateFailed() == [.setBitDepth(16, fromSampleRate: nil)])
        #expect(formats.deviceRateFailed() == [])
    }

    @Test func aNewSelectionReplacesTheWaitingOne() {
        var formats = FormatSwitch()
        _ = formats.select(sampleRate: 96_000, bitDepth: 24, deviceRate: 48_000)
        #expect(formats.select(sampleRate: 48_000, bitDepth: 16, deviceRate: 48_000)
            == [.setBitDepth(16, fromSampleRate: nil)])
        #expect(formats.deviceRateFailed() == [])
    }
}

struct GroupBitDepthTests {
    static func block(rate: Int) -> PCMBuffer {
        PCMBuffer(samples: [Float](repeating: 0, count: rate / 50 * 2), sampleRate: rate, channels: 2)
    }

    @Test func aBitDepthForARateWaitsForItsFirstBlock() async {
        let group = PlaybackGroup(name: "test", leadMs: 300)
        await group.setPreferredBitDepth(24, fromSampleRate: 96_000)
        await group.push(Self.block(rate: 48_000), captureTimeUs: ServerClock.nowMicros())
        #expect(await group.preferredBitDepth == 16)
        await group.push(Self.block(rate: 96_000), captureTimeUs: ServerClock.nowMicros())
        #expect(await group.preferredBitDepth == 24)
    }

    @Test func aBitDepthWithoutARateGoesNowAndCancelsOneWaiting() async {
        let group = PlaybackGroup(name: "test", leadMs: 300)
        await group.setPreferredBitDepth(24, fromSampleRate: 96_000)
        await group.setPreferredBitDepth(16)
        await group.push(Self.block(rate: 96_000), captureTimeUs: ServerClock.nowMicros())
        #expect(await group.preferredBitDepth == 16)
    }
}
