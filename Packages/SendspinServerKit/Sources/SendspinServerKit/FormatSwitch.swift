/// Puts a stream format into effect: the Sendspin device's sample rate and the bit depth the
/// group streams. Changing either makes players restart their stream, a gap in the audio, so
/// with a new rate the bit depth waits for the first block at that rate
/// (`PlaybackGroup.setPreferredBitDepth(_:fromSampleRate:)`): one restart per switch, not two,
/// however soon capture delivers the new rate. The group is told before the rate changes.
public struct FormatSwitch: Sendable {
    public enum Action: Equatable, Sendable {
        case setDeviceRate(Int)
        /// The bit depth, from now on (no rate) or from the first block at a rate.
        case setBitDepth(Int, fromSampleRate: Int?)
    }

    /// The bit depth that waits for a rate change.
    public private(set) var waitingBitDepth: Int?

    public init() {}

    /// Select a format while the device runs at `deviceRate`.
    public mutating func select(sampleRate: Int, bitDepth: Int, deviceRate: Int) -> [Action] {
        guard sampleRate != deviceRate else {
            waitingBitDepth = nil
            return [.setBitDepth(bitDepth, fromSampleRate: nil)]
        }
        waitingBitDepth = bitDepth
        return [.setBitDepth(bitDepth, fromSampleRate: sampleRate), .setDeviceRate(sampleRate)]
    }

    /// The device runs at a new rate (asked for, or changed elsewhere, e.g. Audio MIDI Setup).
    /// The group already switched the bit depth at its first block.
    public mutating func deviceRateChanged() {
        waitingBitDepth = nil
    }

    /// The rate couldn't be changed: the bit depth goes ahead on its own.
    public mutating func deviceRateFailed() -> [Action] {
        defer { waitingBitDepth = nil }
        return waitingBitDepth.map { [.setBitDepth($0, fromSampleRate: nil)] } ?? []
    }
}
