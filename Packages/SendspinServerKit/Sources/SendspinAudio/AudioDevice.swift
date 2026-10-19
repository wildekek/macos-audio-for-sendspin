import CoreAudio
import Foundation

public enum AudioDeviceError: Error, CustomStringConvertible {
    case notFound(String)
    case coreAudio(String, OSStatus)

    public var description: String {
        switch self {
        case .notFound(let what): "no audio device \(what)"
        case .coreAudio(let call, let status): "\(call) failed (OSStatus \(status))"
        }
    }
}

func check(_ call: String, _ status: OSStatus) throws {
    if status != noErr { throw AudioDeviceError.coreAudio(call, status) }
}

/// A CoreAudio device, with the properties the bridge reads and controls.
public struct AudioDevice: Hashable, Sendable {
    public let id: AudioObjectID

    /// UID of the device published by the Sendspin driver.
    public static let sendspinUID = "eu.vooijs.SendspinForMac.Device"
    /// Custom driver property 'sslt': output presentation latency in frames.
    static let presentationLatencySelector: AudioObjectPropertySelector = 0x7373_6C74

    public init(id: AudioObjectID) {
        self.id = id
    }

    // MARK: Lookup

    public static var sendspin: AudioDevice? { find(uid: sendspinUID) }

    public static func find(uid: String) -> AudioDevice? {
        var cfUID = uid as CFString
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = globalAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        let status = withUnsafePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? AudioDevice(id: device) : nil
    }

    public static func all() -> [AudioDevice] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map(AudioDevice.init)
    }

    /// First input device whose name contains `query` (case-insensitive).
    public static func input(matching query: String) throws -> AudioDevice {
        guard let device = all().first(where: {
            $0.channelCount(scope: kAudioObjectPropertyScopeInput) > 0
                && ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
        }) else { throw AudioDeviceError.notFound("matching \"\(query)\"") }
        return device
    }

    /// First output device whose name contains `query` (case-insensitive).
    public static func output(matching query: String) throws -> AudioDevice {
        guard let device = all().first(where: {
            $0.channelCount(scope: kAudioObjectPropertyScopeOutput) > 0
                && ($0.name?.localizedCaseInsensitiveContains(query) ?? false)
        }) else { throw AudioDeviceError.notFound("matching \"\(query)\"") }
        return device
    }

    // MARK: Properties

    public var name: String? { string(kAudioObjectPropertyName) }
    public var uid: String? { string(kAudioDevicePropertyDeviceUID) }

    public func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Output volume scalar, 0…1.
    public var volume: Float32? {
        get { scalar(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, as: Float32.self) }
        nonmutating set {
            guard let newValue else { return }
            setScalar(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, max(0, min(1, newValue)))
        }
    }

    public var isMuted: Bool? {
        get { scalar(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, as: UInt32.self).map { $0 != 0 } }
        nonmutating set {
            guard let newValue else { return }
            setScalar(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(newValue ? 1 : 0))
        }
    }

    /// Whether any process is doing IO on the device (someone is playing into it).
    public var isRunningSomewhere: Bool {
        scalar(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, as: UInt32.self)
            .map { $0 != 0 } ?? false
    }

    /// Ask the Sendspin driver to report this output latency, so apps can keep A/V sync.
    public func setPresentationLatency(frames: Int) throws {
        var address = Self.globalAddress(Self.presentationLatencySelector)
        var number: CFPropertyList = NSNumber(value: Int32(clamping: frames))
        let status = withUnsafePointer(to: &number) {
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
        try check("set presentation latency", status)
    }

    // MARK: Default output

    public static var defaultOutput: AudioDevice? {
        let address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        return AudioDevice(id: AudioObjectID(kAudioObjectSystemObject))
            .scalar(address.mSelector, address.mScope, as: AudioObjectID.self)
            .flatMap { $0 == kAudioObjectUnknown ? nil : AudioDevice(id: $0) }
    }

    public static func setDefaultOutput(_ device: AudioDevice) throws {
        var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = device.id
        try check("set default output", AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &deviceID))
    }

    // MARK: Listening

    /// Call `handler` on `queue` whenever the property changes. Keep the token alive.
    public func observe(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        queue: DispatchQueue = .main,
                        _ handler: @escaping @Sendable () -> Void) -> PropertyObservation {
        PropertyObservation(object: id, address: Self.address(selector, scope), queue: queue, handler: handler)
    }

    public static func observeSystem(_ selector: AudioObjectPropertySelector, queue: DispatchQueue = .main,
                                     _ handler: @escaping @Sendable () -> Void) -> PropertyObservation {
        PropertyObservation(object: AudioObjectID(kAudioObjectSystemObject), address: globalAddress(selector),
                            queue: queue, handler: handler)
    }

    // MARK: Helpers

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        address(selector, kAudioObjectPropertyScopeGlobal)
    }

    private func string(_ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func scalar<T>(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                           as _: T.Type) -> T? {
        var address = Self.address(selector, scope)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, value) == noErr ? value.pointee : nil
    }

    private func setScalar<T: BitwiseCopyable>(_ selector: AudioObjectPropertySelector,
                                               _ scope: AudioObjectPropertyScope, _ value: T) {
        var address = Self.address(selector, scope)
        withUnsafePointer(to: value) {
            _ = AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }
}

/// A registered CoreAudio property listener; removed when released.
public final class PropertyObservation: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
         handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}

// MARK: - Latency reporting

extension AudioDevice {
    public static var defaultInput: AudioDevice? {
        AudioDevice(id: AudioObjectID(kAudioObjectSystemObject))
            .scalar(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, as: AudioObjectID.self)
            .flatMap { $0 == kAudioObjectUnknown ? nil : AudioDevice(id: $0) }
    }

    /// Switch the device's sample rate (applied asynchronously by the HAL).
    public func setNominalSampleRate(_ rate: Double) throws {
        var address = Self.address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal)
        var value = Float64(rate)
        try check("set sample rate", AudioObjectSetPropertyData(
            id, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value))
    }

    /// Sample rates the device offers (each listed as a single rate).
    public var availableSampleRates: [Double] {
        var address = Self.address(kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map(\.mMinimum)
    }

    public var nominalSampleRate: Double {
        scalar(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, as: Float64.self) ?? 48_000
    }

    /// Latency the device reports to apps for one direction: device latency + safety
    /// offset + the first stream's latency, in µs. For output this is how long after its
    /// render timestamp a sample is heard; for input, how long before its capture
    /// timestamp a sample actually reached the device.
    public func reportedLatencyUs(scope: AudioObjectPropertyScope) -> Int64 {
        func frames(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope) -> UInt32 {
            AudioDevice(id: object).scalar(selector, scope, as: UInt32.self) ?? 0
        }
        var total = frames(id, kAudioDevicePropertyLatency, scope) + frames(id, kAudioDevicePropertySafetyOffset, scope)
        var address = Self.address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 {
            var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &streams) == noErr, let first = streams.first {
                total += frames(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return Int64(Double(total) / nominalSampleRate * 1_000_000)
    }
}
