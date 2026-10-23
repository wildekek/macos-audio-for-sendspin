import Testing
@testable import SendspinServerKit

struct FormatSwitchTests {
    @Test func aBitDepthAtTheSameRateGoesStraightAway() {
        var formats = FormatSwitch()
        #expect(formats.select(sampleRate: 48_000, bitDepth: 24, deviceRate: 48_000) == [.setBitDepth(24)])
        #expect(formats.waitingBitDepth == nil)
    }

    @Test func withANewRateTheBitDepthWaitsForIt() {
        var formats = FormatSwitch()
        #expect(formats.select(sampleRate: 96_000, bitDepth: 24, deviceRate: 48_000) == [.setDeviceRate(96_000)])
        #expect(formats.waitingBitDepth == 24)
        #expect(formats.deviceRateChanged() == [.setBitDepth(24)])
        // Once only.
        #expect(formats.deviceRateChanged() == [])
    }

    @Test func aRateChangedElsewhereLeavesTheBitDepth() {
        var formats = FormatSwitch()
        #expect(formats.deviceRateChanged() == [])
    }

    @Test func aFailedRateChangeLetsTheBitDepthGo() {
        var formats = FormatSwitch()
        _ = formats.select(sampleRate: 192_000, bitDepth: 16, deviceRate: 44_100)
        #expect(formats.deviceRateFailed() == [.setBitDepth(16)])
    }

    @Test func aNewSelectionReplacesTheWaitingOne() {
        var formats = FormatSwitch()
        _ = formats.select(sampleRate: 96_000, bitDepth: 24, deviceRate: 48_000)
        #expect(formats.select(sampleRate: 48_000, bitDepth: 16, deviceRate: 48_000) == [.setBitDepth(16)])
        #expect(formats.deviceRateChanged() == [])
    }
}
