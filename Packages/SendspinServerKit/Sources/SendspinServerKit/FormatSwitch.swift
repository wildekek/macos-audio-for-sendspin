/// Puts a stream format into effect: the Sendspin device's sample rate and the bit depth the
/// group streams. Changing either makes players restart their stream, a gap in the audio, so
/// with a new rate the bit depth waits until the device runs at it: one restart per switch,
/// not two.
public struct FormatSwitch: Sendable {
    public enum Action: Equatable, Sendable {
        case setDeviceRate(Int)
        case setBitDepth(Int)
    }

    /// The bit depth that waits for a rate change.
    public private(set) var waitingBitDepth: Int?

    public init() {}

    /// Select a format while the device runs at `deviceRate`.
    public mutating func select(sampleRate: Int, bitDepth: Int, deviceRate: Int) -> [Action] {
        guard sampleRate != deviceRate else {
            waitingBitDepth = nil
            return [.setBitDepth(bitDepth)]
        }
        waitingBitDepth = bitDepth
        return [.setDeviceRate(sampleRate)]
    }

    /// The device runs at a new rate (asked for, or changed elsewhere, e.g. Audio MIDI Setup).
    public mutating func deviceRateChanged() -> [Action] {
        defer { waitingBitDepth = nil }
        return waitingBitDepth.map { [.setBitDepth($0)] } ?? []
    }

    /// The rate couldn't be changed: the bit depth goes ahead on its own.
    public mutating func deviceRateFailed() -> [Action] {
        deviceRateChanged()
    }
}
